"""Revisioned, evidence-based theme composition state."""
from __future__ import annotations

import copy
import base64
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .core import canonical_json, state_home

SCHEMA_VERSION = 1
LEDGER_NAME = "composition.json"
LOCK_NAME = "composition.lock"
MAX_LEDGER_BYTES = 1024 * 1024
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
STATUSES = {
    "managed", "externally-modified", "unknown", "pending", "unapplied", "unavailable",
}
OBSERVATION_STATES = {"pending", "unapplied", "unavailable"}
COMPONENT_MANIFEST = Path(__file__).resolve().parents[2] / "schema" / "components-v1.json"


class CompositionError(ValueError):
    """The evidence record or its state path is unsafe or invalid."""


class CompositionConflict(CompositionError):
    """The caller's expected ledger revision is stale."""


def _component_ids() -> tuple[str, ...]:
    manifest = json.loads(COMPONENT_MANIFEST.read_text(encoding="utf-8"))
    return tuple(
        component["id"] for component in manifest["components"]
        if component["id"] != "settings-document"
    )


def _timestamp(value: str | None = None) -> str:
    if value is None:
        return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    if not isinstance(value, str):
        raise CompositionError("observation time must be an ISO timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise CompositionError("observation time must be an ISO timestamp") from error
    if parsed.tzinfo is None:
        raise CompositionError("observation time must include a timezone")
    return parsed.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or not DIGEST_PATTERN.fullmatch(value):
        raise CompositionError(f"{field} must be a lower-case SHA-256 digest")
    return value


def component_digest(value: Any) -> str:
    """Hash a JSON component without retaining its contents in the ledger."""
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def empty_ledger(observed_at: str | None = None) -> dict[str, Any]:
    stamp = _timestamp(observed_at)
    ledger = {
        "schemaVersion": SCHEMA_VERSION,
        "revision": 0,
        "observedAt": stamp,
        "activeTheme": None,
        "managedComponents": [],
        "components": {
            component_id: {
                "status": "unknown",
                "observed": {"revision": None, "digest": None, "at": stamp},
                "lastManaged": None,
            }
            for component_id in _component_ids()
        },
    }
    validate_ledger(ledger)
    return ledger


def _active_theme(ledger: dict[str, Any]) -> dict[str, Any] | None:
    managed_ids = ledger["managedComponents"]
    if not {"theme-metadata", "appearance"}.issubset(managed_ids):
        return None
    source: tuple[str, str] | None = None
    for component_id in managed_ids:
        component = ledger["components"][component_id]
        history = component["lastManaged"]
        if component["status"] != "managed" or history is None:
            return None
        current = (history["themeId"], history["sourceDigest"])
        if source is None:
            source = current
        elif source != current:
            return None
    if source is None:
        return None
    return {
        "themeId": source[0],
        "sourceDigest": source[1],
        "components": list(managed_ids),
        "observedAt": ledger["observedAt"],
    }


def _refresh_claims(ledger: dict[str, Any]) -> None:
    ledger["managedComponents"] = sorted(set(ledger["managedComponents"]))
    ledger["activeTheme"] = _active_theme(ledger)


def validate_ledger(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "revision", "observedAt", "activeTheme", "managedComponents", "components",
    }:
        raise CompositionError("composition ledger has an invalid structure")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != SCHEMA_VERSION:
        raise CompositionError("unsupported composition ledger version")
    if type(value["revision"]) is not int or value["revision"] < 0:
        raise CompositionError("composition revision must be a non-negative integer")
    _timestamp(value["observedAt"])
    component_ids = set(_component_ids())
    if not isinstance(value["components"], dict) or set(value["components"]) != component_ids:
        raise CompositionError("composition components differ from the installed manifest")
    if (not isinstance(value["managedComponents"], list)
            or not all(isinstance(component_id, str) for component_id in value["managedComponents"])
            or len(value["managedComponents"]) != len(set(value["managedComponents"]))
            or not set(value["managedComponents"]).issubset(component_ids)):
        raise CompositionError("managed component list is invalid")
    for component_id, component in value["components"].items():
        if not isinstance(component, dict) or set(component) != {"status", "observed", "lastManaged"}:
            raise CompositionError(f"invalid component record: {component_id}")
        if not isinstance(component["status"], str) or component["status"] not in STATUSES:
            raise CompositionError(f"invalid component status: {component_id}")
        observed = component["observed"]
        if not isinstance(observed, dict) or set(observed) != {"revision", "digest", "at"}:
            raise CompositionError(f"invalid observation record: {component_id}")
        revision = observed["revision"]
        if revision is not None and (type(revision) is not int or revision < 0):
            raise CompositionError(f"invalid observed revision: {component_id}")
        if observed["digest"] is not None:
            _digest(observed["digest"], "observed digest")
        _timestamp(observed["at"])
        history = component["lastManaged"]
        if history is not None:
            if not isinstance(history, dict) or set(history) != {
                "themeId", "sourceDigest", "generationId", "revision", "digest", "managedAt",
            }:
                raise CompositionError(f"invalid last-managed history: {component_id}")
            if not isinstance(history["themeId"], str) or not history["themeId"]:
                raise CompositionError(f"invalid last-managed theme: {component_id}")
            _digest(history["sourceDigest"], "last-managed source digest")
            _digest(history["digest"], "last-managed digest")
            if history["generationId"] is not None and (
                not isinstance(history["generationId"], str) or not history["generationId"]
            ):
                raise CompositionError(f"invalid last-managed generation: {component_id}")
            if history["revision"] is not None and (
                type(history["revision"]) is not int or history["revision"] < 0
            ):
                raise CompositionError(f"invalid last-managed revision: {component_id}")
            _timestamp(history["managedAt"])
        if component["status"] == "managed":
            if history is None or observed["digest"] != history["digest"]:
                raise CompositionError(f"managed component lacks matching evidence: {component_id}")
            if component_id not in value["managedComponents"]:
                raise CompositionError(f"managed component is absent from the current set: {component_id}")
        if component["status"] == "externally-modified":
            if history is None or observed["digest"] is None or observed["digest"] == history["digest"]:
                raise CompositionError(f"external drift lacks changed digest evidence: {component_id}")
            if component_id not in value["managedComponents"]:
                raise CompositionError(f"external component is absent from the current set: {component_id}")
        if component["status"] == "unapplied" and component_id in value["managedComponents"]:
            raise CompositionError(f"unapplied component is present in the current set: {component_id}")
    if any(value["components"][component_id]["lastManaged"] is None
           for component_id in value["managedComponents"]):
        raise CompositionError("current managed component lacks last-managed evidence")
    if value["activeTheme"] != _active_theme(value):
        raise CompositionError("active theme claim does not match current component evidence")


def mark_managed(
    ledger: dict[str, Any],
    component_id: str,
    *,
    theme_id: str,
    source_digest: str,
    generation_id: str | None,
    revision: int | None,
    digest: str,
    observed_at: str | None = None,
) -> dict[str, Any]:
    """Record a component only after its owner has verified the applied result."""
    validate_ledger(ledger)
    if component_id not in ledger["components"]:
        raise CompositionError(f"unknown component: {component_id}")
    if not isinstance(theme_id, str) or not theme_id:
        raise CompositionError("managed theme ID is required")
    source_digest = _digest(source_digest, "source digest")
    digest = _digest(digest, "component digest")
    if generation_id is not None and (not isinstance(generation_id, str) or not generation_id):
        raise CompositionError("generation ID must be a non-empty string or null")
    if revision is not None and (type(revision) is not int or revision < 0):
        raise CompositionError("observed revision must be a non-negative integer or null")
    stamp = _timestamp(observed_at)
    result = copy.deepcopy(ledger)
    result["observedAt"] = stamp
    result["components"][component_id] = {
        "status": "managed",
        "observed": {"revision": revision, "digest": digest, "at": stamp},
        "lastManaged": {
            "themeId": theme_id,
            "sourceDigest": source_digest,
            "generationId": generation_id,
            "revision": revision,
            "digest": digest,
            "managedAt": stamp,
        },
    }
    result["managedComponents"].append(component_id)
    _refresh_claims(result)
    validate_ledger(result)
    return result


def observe_component(
    ledger: dict[str, Any],
    component_id: str,
    *,
    revision: int | None = None,
    digest: str | None = None,
    observed_at: str | None = None,
    state: str | None = None,
) -> dict[str, Any]:
    """Compare owner evidence with the last verified digest and preserve history."""
    validate_ledger(ledger)
    if component_id not in ledger["components"]:
        raise CompositionError(f"unknown component: {component_id}")
    if state is not None and state not in OBSERVATION_STATES:
        raise CompositionError("observed state must be pending, unapplied or unavailable")
    if revision is not None and (type(revision) is not int or revision < 0):
        raise CompositionError("observed revision must be a non-negative integer or null")
    if digest is not None:
        _digest(digest, "observed digest")
    stamp = _timestamp(observed_at)
    result = copy.deepcopy(ledger)
    prior = result["components"][component_id]["lastManaged"]
    if state is None:
        if digest is None:
            status = "unknown"
        elif prior is None:
            status = "unknown"
        elif digest == prior["digest"]:
            status = "managed"
        else:
            status = "externally-modified"
    else:
        status = state
    result["observedAt"] = stamp
    result["components"][component_id] = {
        "status": status,
        "observed": {"revision": revision, "digest": digest, "at": stamp},
        "lastManaged": prior,
    }
    if status == "managed" or status == "externally-modified":
        if component_id not in result["managedComponents"]:
            result["managedComponents"].append(component_id)
    elif status == "unapplied":
        result["managedComponents"] = [
            item for item in result["managedComponents"] if item != component_id
        ]
    _refresh_claims(result)
    validate_ledger(result)
    return result


class CompositionDocument:
    """Store the evidence ledger beneath the owner-only XDG state root."""

    def __init__(self, root: str | Path | None = None):
        self.root = Path(root or state_home()).expanduser()
        if not self.root.is_absolute() or ".." in self.root.parts:
            raise CompositionError("XDG state root must be absolute and contain no parent traversal")
        self.directory = self.root / "blox" / "theme"

    def _open_directory(self, create: bool) -> int:
        descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            parts = self.directory.parts[1:]
            for index, part in enumerate(parts):
                try:
                    next_descriptor = os.open(
                        part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=descriptor,
                    )
                except FileNotFoundError:
                    if not create:
                        raise
                    try:
                        os.mkdir(part, 0o700, dir_fd=descriptor)
                    except FileExistsError:
                        pass
                    next_descriptor = os.open(
                        part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=descriptor,
                    )
                os.close(descriptor)
                descriptor = next_descriptor
                info = os.fstat(descriptor)
                if index == len(parts) - 3 and info.st_uid != os.getuid():
                    raise PermissionError("foreign XDG state directory")
                if index >= len(parts) - 2 and (
                    info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077
                ):
                    raise PermissionError("composition state directory is not owner-only")
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    @staticmethod
    def _identity(dfd: int) -> tuple[int, int, int, int, int] | None:
        try:
            info = os.stat(LEDGER_NAME, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        return info.st_dev, info.st_ino, info.st_ctime_ns, info.st_mtime_ns, info.st_size

    @staticmethod
    def _read_at(dfd: int) -> dict[str, Any] | None:
        try:
            descriptor = os.open(
                LEDGER_NAME,
                os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=dfd,
            )
        except FileNotFoundError:
            return None
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                    or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > MAX_LEDGER_BYTES):
                raise PermissionError("unsafe composition ledger")
            with os.fdopen(descriptor, "rb", closefd=False) as stream:
                payload = stream.read(MAX_LEDGER_BYTES + 1)
            if len(payload) > MAX_LEDGER_BYTES:
                raise CompositionError("composition ledger is oversized")

            def unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
                result = {}
                for key, item in pairs:
                    if key in result:
                        raise CompositionError(f"duplicate composition key: {key}")
                    result[key] = item
                return result

            value = json.loads(payload, object_pairs_hook=unique_pairs)
            validate_ledger(value)
            return value
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CompositionError("composition ledger is invalid JSON") from error
        finally:
            os.close(descriptor)

    def read(self) -> dict[str, Any]:
        try:
            dfd = self._open_directory(False)
        except FileNotFoundError:
            return empty_ledger()
        try:
            value = self._read_at(dfd)
            return value if value is not None else empty_ledger()
        finally:
            os.close(dfd)

    def capture_preimage(self) -> dict[str, Any]:
        """Capture exact bytes and mode, including an absent ledger."""
        try:
            dfd = self._open_directory(False)
        except FileNotFoundError:
            return {"bytes": None, "mode": None}
        try:
            identity = self._identity(dfd)
            if self._read_at(dfd) is None:
                return {"bytes": None, "mode": None}
            fd = os.open(LEDGER_NAME, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
            try:
                with os.fdopen(fd, "rb", closefd=False) as stream:
                    payload = stream.read(MAX_LEDGER_BYTES + 1)
                mode = stat.S_IMODE(os.fstat(fd).st_mode)
            finally:
                os.close(fd)
            if self._identity(dfd) != identity:
                raise CompositionConflict("composition changed during capture")
            return {"bytes": base64.b64encode(payload).decode("ascii"), "mode": mode}
        finally:
            os.close(dfd)

    @staticmethod
    def validate_preimage(image: Any) -> dict[str, Any] | None:
        if not isinstance(image, dict) or set(image) != {"bytes", "mode"}:
            raise CompositionError("invalid composition pre-image")
        if image["bytes"] is None:
            if image["mode"] is not None:
                raise CompositionError("invalid absent composition pre-image")
            return None
        if type(image["mode"]) is not int or not 0 <= image["mode"] <= 0o777 or image["mode"] & 0o077:
            raise CompositionError("invalid composition pre-image mode")
        try:
            payload = base64.b64decode(image["bytes"], validate=True)
            if len(payload) > MAX_LEDGER_BYTES:
                raise CompositionError("composition pre-image is oversized")
            value = json.loads(payload)
            validate_ledger(value)
            return value
        except (ValueError, TypeError) as error:
            raise CompositionError("invalid composition pre-image bytes") from error

    def restore_preimage(self, image: dict[str, Any], *, expected_revision: int) -> None:
        """Restore an Apply pre-image under the same revision and path guards."""
        value = self.validate_preimage(image)
        self._transact(lambda current: value or empty_ledger(), expected_revision=expected_revision, restore_image=image)

    def update(self, mutate: Callable[[dict[str, Any]], dict[str, Any]], *, expected_revision: int) -> dict[str, Any]:
        return self._transact(mutate, expected_revision=expected_revision)

    def _transact(
        self,
        mutate: Callable[[dict[str, Any]], dict[str, Any]],
        *,
        expected_revision: int,
        restore_image: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if type(expected_revision) is not int or expected_revision < 0:
            raise CompositionError("expected revision must be a non-negative integer")
        dfd = self._open_directory(True)
        lockfd = -1
        temporary_name: str | None = None
        try:
            lockfd = os.open(
                LOCK_NAME,
                os.O_RDWR | os.O_NONBLOCK | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=dfd,
            )
            lock_info = os.fstat(lockfd)
            if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid()
                    or lock_info.st_nlink != 1 or stat.S_IMODE(lock_info.st_mode) & 0o077):
                raise PermissionError("unsafe composition lock")
            fcntl.flock(lockfd, fcntl.LOCK_EX)
            identity = self._identity(dfd)
            current = self._read_at(dfd)
            if current is None:
                current = empty_ledger()
            if current["revision"] != expected_revision:
                raise CompositionConflict("composition revision conflict")
            candidate = mutate(copy.deepcopy(current))
            if not isinstance(candidate, dict):
                raise CompositionError("composition mutation must return a ledger")
            if restore_image is None:
                candidate["revision"] = current["revision"] + 1
            validate_ledger(candidate)
            encoded = canonical_json(candidate).encode("utf-8") if restore_image is None else (
                base64.b64decode(restore_image["bytes"], validate=True) if restore_image["bytes"] is not None else None)
            if encoded is None:
                if self._identity(dfd) != identity:
                    raise CompositionConflict("composition path changed during restore")
                if identity is not None:
                    os.unlink(LEDGER_NAME, dir_fd=dfd)
                    os.fsync(dfd)
                return candidate
            if len(encoded) > MAX_LEDGER_BYTES:
                raise CompositionError("composition ledger is oversized")
            if self._identity(dfd) != identity:
                raise CompositionConflict("composition path changed during update")
            temporary_name = f".composition-{os.getpid()}-{secrets.token_hex(8)}.tmp"
            tempfd = os.open(
                temporary_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=dfd,
            )
            try:
                with os.fdopen(tempfd, "wb", closefd=False) as stream:
                    stream.write(encoded)
                    if restore_image is not None:
                        os.fchmod(tempfd, restore_image["mode"])
                    stream.flush()
                    os.fsync(tempfd)
            finally:
                os.close(tempfd)
            if self._identity(dfd) != identity:
                raise CompositionConflict("composition path changed during update")
            os.replace(
                temporary_name, LEDGER_NAME, src_dir_fd=dfd, dst_dir_fd=dfd,
            )
            temporary_name = None
            os.fsync(dfd)
            return candidate
        finally:
            if temporary_name is not None:
                try:
                    os.unlink(temporary_name, dir_fd=dfd)
                except FileNotFoundError:
                    pass
            if lockfd >= 0:
                fcntl.flock(lockfd, fcntl.LOCK_UN)
                os.close(lockfd)
            os.close(dfd)


def targets_and_files(generation_path: str | Path, manifest: dict[str, Any]) -> list[dict[str, Any]]:
    """Project validated generation provenance for the Targets & files view."""
    from .runtime import LEGACY_TARGET_FILES, TARGET_FILES

    if not isinstance(manifest, dict):
        raise CompositionError("generation manifest must be an object")
    generation_id = manifest.get("generation_id")
    generated_at = manifest.get("created_at")
    sources = manifest.get("target_sources")
    file_digests = manifest.get("files")
    enabled = manifest.get("enabled_targets")
    if (not isinstance(generation_id, str) or not generation_id
            or not isinstance(sources, dict) or not isinstance(file_digests, dict)
            or not isinstance(enabled, list)
            or not all(isinstance(target, str) for target in enabled)
            or len(enabled) != len(set(enabled))):
        raise CompositionError("generation provenance is incomplete")
    generated_at = _timestamp(generated_at)
    base = Path(generation_path).expanduser().resolve()
    result = []
    for target in enabled:
        if target not in TARGET_FILES:
            raise CompositionError(f"unknown generated target: {target}")
        source = sources.get(target)
        if not isinstance(source, dict):
            raise CompositionError(f"target source is unavailable: {target}")
        theme_id = source.get("theme_id")
        source_digest = source.get("source_sha256")
        if not isinstance(theme_id, str) or not theme_id:
            raise CompositionError(f"target theme identity is invalid: {target}")
        _digest(source_digest, "target source digest")
        target_names = set(TARGET_FILES[target])
        target_names.update(name for name, owner in LEGACY_TARGET_FILES.items() if owner == target)
        files = []
        for name in sorted(target_names.intersection(file_digests)):
            digest = _digest(file_digests[name], "generated file digest")
            files.append({"path": str(base / name), "digest": digest})
        if not files:
            raise CompositionError(f"target has no generated files: {target}")
        result.append({
            "target": target,
            "generationId": generation_id,
            "themeId": theme_id,
            "sourceDigest": source_digest,
            "generatedAt": generated_at,
            "files": files,
        })
    return result
