"""Safe, revisioned persistence for the user Settings document."""

from __future__ import annotations

import copy
from contextlib import contextmanager, ExitStack
import fcntl
import json
import os
import secrets
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent / "contracts"
CURRENT_VERSION = 1


class FutureVersionError(ValueError):
    """A newer owner may understand this document; do not recover past it."""


@dataclass(frozen=True)
class SettingsResult:
    ok: bool
    code: str
    data: Any = None
    revision: int | None = None
    before_revision: int | None = None
    changed: tuple[str, ...] = ()
    committed: bool = False
    observed_at: float = 0.0


class SettingsDocument:
    """Operate only beneath an owned XDG config root using directory fds."""

    def __init__(self, root: str | Path | None = None,
                 fault: Callable[[str], None] | None = None):
        self.root = Path(root or os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        if not self.root.is_absolute():
            raise ValueError("XDG config root must be absolute")
        self.fault = fault or (lambda point: None)
        self.defaults = json.loads((ROOT / "settings-defaults-v1.json").read_text())
        self.schema = json.loads((ROOT / "settings-v1.schema.json").read_text())

    def _dir(self, create: bool) -> int:
        # Resolve/open each component without following symlinks. Only the
        # application-owned `blox` directory is created by this class.
        parts = self.root.parts
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in parts[1:]:
                try:
                    nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    if not create or part != "blox":
                        raise
                    try:
                        os.mkdir(part, 0o700, dir_fd=fd)
                    except FileExistsError:
                        # Another writer may create it before acquiring the lock.
                        pass
                    nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = nxt
                st = os.fstat(fd)
                if part == parts[-1] and st.st_uid != os.getuid():
                    raise PermissionError("foreign config directory")
            try:
                appfd = os.open("blox", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir("blox", 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                appfd = os.open("blox", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = appfd
            st = os.fstat(fd)
            if st.st_uid != os.getuid():
                raise PermissionError("foreign application directory")
            if stat.S_IMODE(st.st_mode) & 0o077:
                raise PermissionError("application directory is not owner-only")
            return fd
        except BaseException:
            os.close(fd)
            raise

    def _read_bytes_at(self, dfd: int, name: str) -> bytes | None:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                         dir_fd=dfd)
        except FileNotFoundError:
            return None
        try:
            st = os.fstat(fd)
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1
                    or stat.S_IMODE(st.st_mode) & 0o077):
                raise PermissionError("unsafe or foreign settings file")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                return stream.read()
        finally:
            os.close(fd)

    def _read_at(self, dfd: int, name: str) -> dict | None:
        raw = self._read_bytes_at(dfd, name)
        if raw is None:
            return None
        def unique_pairs(pairs: list[tuple[str, Any]]) -> dict:
            result = {}
            for key, item in pairs:
                if key in result:
                    raise ValueError(f"duplicate key: {key}")
                result[key] = item
            return result
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_pairs)
        if not isinstance(value, dict):
            raise ValueError("settings document must be an object")
        return value

    def _select_preimage(self, dfd: int, *, inspect_backup: bool = False) -> tuple[dict, tuple[str, ...]]:
        """Reads and locked writes select the same validated recovery document."""
        corrupt = []
        try:
            primary = self._read_at(dfd, "settings.json")
            primary = self._migrate(primary) if primary is not None else None
        except FutureVersionError:
            raise
        except (ValueError, TypeError) as error:
            corrupt.append("settings.json")
            primary_error = error
            primary = None
        if primary is not None and not inspect_backup:
            return primary, ()
        try:
            backup = self._read_at(dfd, "settings.json.bak")
            backup = self._migrate(backup) if backup is not None else None
        except FutureVersionError:
            raise
        except (ValueError, TypeError):
            if primary is None:
                raise
            corrupt.append("settings.json.bak")
            backup = None
        if primary is None and backup is None and corrupt:
            raise primary_error
        selected = primary if primary is not None else backup
        return copy.deepcopy(self.defaults) if selected is None else selected, tuple(corrupt)

    def _preserve_corrupt(self, dfd: int, name: str) -> None:
        """Keep exact invalid bytes privately before replacing their source."""
        raw = self._read_bytes_at(dfd, name)
        if raw is None:
            raise PermissionError("corrupt Settings source disappeared")
        diagnostic = f"{name}.corrupt.{secrets.token_hex(12)}"
        fd = os.open(diagnostic, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "wb", closefd=False) as stream:
                stream.write(raw)
                stream.flush()
            os.fsync(fd)
            os.fsync(dfd)
        except BaseException:
            os.unlink(diagnostic, dir_fd=dfd)
            raise
        finally:
            os.close(fd)

    def _identity_at(self, dfd: int, name: str) -> tuple[int, int, int, int, int] | None:
        try:
            st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        return st.st_dev, st.st_ino, st.st_ctime_ns, st.st_mtime_ns, st.st_size

    def _check_identity(self, dfd: int, name: str,
                        expected: tuple[int, int, int, int, int] | None) -> None:
        if self._identity_at(dfd, name) != expected:
            raise PermissionError(f"settings path changed during transaction: {name}")

    def _validate(self, data: dict) -> None:
        from themes.lib.blox_theme.core import widget_model
        widget_model().validate_profile(data.get("widgets"))
        try:
            import jsonschema
            try:
                jsonschema.validate(data, self.schema)
            except jsonschema.ValidationError as exc:
                raise ValueError(str(exc)) from exc
        except ImportError:
            from themes.lib.blox_theme.core import _basic_schema_errors
            errors = _basic_schema_errors(data, self.schema, self.schema)
            if errors:
                raise ValueError("; ".join(errors))

    def _migrate(self, value: dict) -> dict:
        version = value.get("schemaVersion")
        if type(version) is int and version > CURRENT_VERSION:
            raise FutureVersionError("unsupported future settings schema version")
        if type(version) is not int or version < 0:
            raise ValueError("unsupported settings schema version")
        result = copy.deepcopy(value)
        def fill(base: Any, supplied: Any, root: bool = False) -> Any:
            if isinstance(base, dict) and isinstance(supplied, dict):
                merged = copy.deepcopy(base)
                for key, item in supplied.items():
                    merged[key] = fill(merged[key], item) if key in merged and not (root and key == "widgets") else copy.deepcopy(item)
                return merged
            return copy.deepcopy(supplied)
        # Version zero is the pre-versioned form. Each known transition is
        # explicit; defaults fill newly introduced fields without erasing data.
        while version < CURRENT_VERSION:
            if version == 0:
                unknown = result.keys() - self.defaults.keys()
                if unknown:
                    raise ValueError(f"unknown settings fields: {sorted(unknown)}")
                migrated = copy.deepcopy(self.defaults)
                migrated.update({k: v for k, v in result.items() if k in migrated and k not in ("schemaVersion",)})
                migrated["schemaVersion"] = 1
                result = migrated
                version = 1
            else:
                raise ValueError("no migration available")
        result = fill(self.defaults, result, root=True)
        self._validate(result)
        return result

    def get(self) -> SettingsResult:
        try:
            dfd = self._dir(False)
        except FileNotFoundError:
            return SettingsResult(True, "ok", copy.deepcopy(self.defaults), 0, observed_at=time.time())
        except OSError as exc:
            return SettingsResult(False, "unsafe", str(exc), observed_at=time.time())
        try:
            value, _ = self._select_preimage(dfd)
            return SettingsResult(True, "ok", value, value["revision"], observed_at=time.time())
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            return SettingsResult(False, "unsafe" if isinstance(exc, (OSError, PermissionError)) else "invalid", str(exc), observed_at=time.time())
        finally:
            os.close(dfd)

    def _write_temp(self, dfd: int, data: dict, label: str) -> str:
        name = f".{label}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            payload = (json.dumps(data, sort_keys=True, indent=2) + "\n").encode()
            with os.fdopen(fd, "wb", closefd=False) as stream:
                stream.write(payload)
                stream.flush()
                self.fault("after_write")
                os.fsync(fd)
            self.fault("after_file_fsync")
        except BaseException:
            os.close(fd)
            try: os.unlink(name, dir_fd=dfd)
            except OSError: pass
            raise
        os.close(fd)
        return name

    @contextmanager
    def _locked_dir(self, create: bool = True):
        """Named owners may hold the Settings lock across publication and recovery."""
        dfd = self._dir(create)
        lockfd = None
        try:
            lockfd = os.open("settings.lock", os.O_RDWR | os.O_NONBLOCK | os.O_CREAT
                             | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dfd)
            st = os.fstat(lockfd)
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1
                    or stat.S_IMODE(st.st_mode) & 0o077):
                raise PermissionError("unsafe settings lock")
            fcntl.flock(lockfd, fcntl.LOCK_EX)
            yield dfd
        finally:
            if lockfd is not None:
                fcntl.flock(lockfd, fcntl.LOCK_UN)
                os.close(lockfd)
            os.close(dfd)

    def _transact(self, mutate: Callable[[dict], tuple[dict, tuple[str, ...]]], expected_revision: int,
                  *, locked_dfd: int | None = None) -> SettingsResult:
        temp = None
        bname = None
        durable = False
        stack = ExitStack()
        try:
            if type(expected_revision) is not int or expected_revision < 0:
                raise ValueError("expected revision must be a non-negative integer")
            dfd = locked_dfd if locked_dfd is not None else stack.enter_context(self._locked_dir())
            destination_identity = self._identity_at(dfd, "settings.json")
            backup_identity = self._identity_at(dfd, "settings.json.bak")
            current, corrupt = self._select_preimage(dfd, inspect_backup=True)
            before = current["revision"]
            if before != expected_revision:
                return SettingsResult(False, "conflict", current, before, before, observed_at=time.time())
            candidate, changed = mutate(copy.deepcopy(current))
            candidate["schemaVersion"] = CURRENT_VERSION
            candidate["revision"] = before + 1
            self._validate(candidate)
            temp = self._write_temp(dfd, candidate, "settings")
            self.fault("before_backup")
            self._check_identity(dfd, "settings.json", destination_identity)
            self._check_identity(dfd, "settings.json.bak", backup_identity)
            for name in corrupt:
                self._preserve_corrupt(dfd, name)
            self._check_identity(dfd, "settings.json", destination_identity)
            self._check_identity(dfd, "settings.json.bak", backup_identity)
            # Back up the selected validated pre-image, including recovery
            # from a damaged primary.
            if destination_identity is not None:
                bname = self._write_temp(dfd, current, "preimage")
                self._check_identity(dfd, "settings.json", destination_identity)
                self._check_identity(dfd, "settings.json.bak", backup_identity)
                os.replace(bname, "settings.json.bak", src_dir_fd=dfd, dst_dir_fd=dfd)
                bname = None
                os.fsync(dfd)
            self.fault("after_backup")
            self._check_identity(dfd, "settings.json", destination_identity)
            os.replace(temp, "settings.json", src_dir_fd=dfd, dst_dir_fd=dfd)
            temp = None
            self.fault("after_replace")
            os.fsync(dfd)
            durable = True
            self.fault("after_directory_fsync")
            return SettingsResult(True, "ok", candidate, candidate["revision"], before, changed, True, time.time())
        except (OSError, ValueError, TypeError, KeyError, IndexError, json.JSONDecodeError) as exc:
            code = "unsafe" if isinstance(exc, (OSError, PermissionError)) else "invalid"
            return SettingsResult(False, code, str(exc),
                                  candidate["revision"] if durable else None,
                                  before if 'before' in locals() else None,
                                  committed=durable, observed_at=time.time())
        except BaseException as exc:
            return SettingsResult(False, "interrupted", str(exc),
                                  candidate["revision"] if durable else None,
                                  before if 'before' in locals() else None,
                                  committed=durable, observed_at=time.time())
        finally:
            if 'dfd' in locals():
                for leftover in (temp, bname):
                    if leftover is not None:
                        try: os.unlink(leftover, dir_fd=dfd)
                        except OSError: pass
            stack.close()

    def set(self, path: str, value: Any, expected_revision: int) -> SettingsResult:
        parts = path.split(".")
        if not parts or parts[0] in ("schemaVersion", "revision") or any(not p for p in parts):
            return SettingsResult(False, "invalid-path")
        def change(doc: dict) -> tuple[dict, tuple[str, ...]]:
            node = doc
            for key in parts[:-1]:
                node = node[key]
            node[parts[-1]] = value
            return doc, (parts[0],)
        return self._transact(change, expected_revision)

    def update_sections(self, updates: dict, expected_revision: int) -> SettingsResult:
        """Commit selected imported sections together under one expected revision."""
        def change(doc: dict) -> tuple[dict, tuple[str, ...]]:
            if not isinstance(updates, dict) or any(key not in self.defaults or key in ("schemaVersion", "revision") for key in updates):
                raise ValueError("unknown settings section")
            doc.update(copy.deepcopy(updates))
            return doc, tuple(sorted(updates))
        return self._transact(change, expected_revision)

    def reset(self, expected_revision: int, section: str | None = None) -> SettingsResult:
        def change(doc: dict) -> tuple[dict, tuple[str, ...]]:
            if section is None:
                fresh = copy.deepcopy(self.defaults)
                return fresh, tuple(k for k in fresh if k not in ("schemaVersion", "revision"))
            if section not in self.defaults or section in ("schemaVersion", "revision"):
                raise ValueError("unknown settings section")
            doc[section] = copy.deepcopy(self.defaults[section])
            return doc, (section,)
        return self._transact(change, expected_revision)
