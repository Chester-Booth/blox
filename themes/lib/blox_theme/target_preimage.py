"""Exact file pre-images for generation owners that also create loader state."""
from __future__ import annotations

import base64
import os
import json
import re
import shutil
import stat
from pathlib import Path
from typing import Any

from . import runtime
from .apply_coordinator import ApplyError

EDITOR_TARGETS = frozenset({"code", "cursor_editor", "zed", "t3code"})
EXTERNAL_TARGETS = EDITOR_TARGETS | {"gtk", "cursor", "obsidian"}

_CACHE_KEY = re.compile(r"[0-9a-f]{64}")
_CACHE_ENTRY_NAME = re.compile(r"(?:[0-9a-f]{64}|\.candidate-[0-9a-f]{64}-[0-9a-f]{32})")


def _cursor_cache_entries() -> tuple[list[str], bool]:
    """Preserve final caches and unfinished compiler candidates already present."""
    caches = runtime.state_dir() / "cursors"
    try:
        fd = _parent(caches / "entry")
    except FileNotFoundError:
        return [], False
    try:
        if os.fstat(fd).st_uid != os.getuid():
            raise ApplyError("cursor cache directory belongs to another user")
        names = []
        with os.scandir(fd) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if not _CACHE_ENTRY_NAME.fullmatch(entry.name):
                    raise ApplyError("cursor cache contains an unknown entry")
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                    raise ApplyError("cursor cache contains a foreign or unsafe entry")
                names.append(entry.name)
        return sorted(names), True
    finally:
        os.close(fd)


def _editor_settings_paths(target: str) -> list[Path]:
    """A dotfiles link owns its literal link and one regular, owned referent."""
    settings = runtime.editor_settings_path(target)
    try:
        fd = _parent(settings)
    except FileNotFoundError:
        return [settings]
    try:
        try:
            info = os.stat(settings.name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return [settings]
        if not stat.S_ISLNK(info.st_mode):
            return [settings]
        if info.st_uid != os.getuid():
            raise ApplyError("editor settings link belongs to another user")
        literal = os.readlink(settings.name, dir_fd=fd)
    finally:
        os.close(fd)
    destination = Path(os.path.abspath(settings.parent / literal))
    try:
        destination_fd = _parent(destination)
        try:
            referent = os.stat(destination.name, dir_fd=destination_fd, follow_symlinks=False)
        finally:
            os.close(destination_fd)
    except OSError as error:
        raise ApplyError("editor settings link has an unsafe or missing referent") from error
    if not stat.S_ISREG(referent.st_mode) or referent.st_uid != os.getuid():
        raise ApplyError("editor settings link must target an owned regular file")
    return [settings, destination]


def paths(target: str, *, image: dict[str, Any] | None = None) -> list[Path]:
    root = runtime.state_dir()
    if target == "gtk":
        return [runtime.gtk_config_path(version) / name
                for version in ("3", "4")
                for name in ("settings.ini", "gtk.css", "gtk-dark.css", "blox-theme.css", "blox-theme-dark.css")] + [runtime.gtk_integration_path(root)]
    if target == "cursor":
        return [runtime.cursor_icon_link(), runtime.cursor_integration_path(root)]
    if target in ("code", "cursor_editor"):
        package = runtime.editor_extensions_path(target) / runtime.EDITOR_EXTENSION_DIR
        package_files = [package / "package.json", package / runtime.EDITOR_THEME_RELATIVE_PATH]
        if package.exists() or package.is_symlink():
            allowed = set(package_files) | {parent for path in package_files for parent in path.parents if parent == package or package in parent.parents}
            if package.is_symlink() or not package.is_dir():
                raise ApplyError("unsafe editor package directory")
            for entry in [package, *package.rglob("*")]:
                info = entry.lstat()
                if entry not in allowed or info.st_uid != os.getuid() or stat.S_ISLNK(info.st_mode):
                    raise ApplyError("editor package contains foreign or unsafe files")
        if image is None:
            settings_paths = _editor_settings_paths(target)
        else:
            settings = runtime.editor_settings_path(target)
            records = image.get("files")
            previous = records.get(str(settings), {}) if isinstance(records, dict) else {}
            settings_paths = [settings]
            if isinstance(previous, dict) and previous.get("kind") == "symlink" and isinstance(previous.get("target"), str):
                settings_paths.append(Path(os.path.abspath(settings.parent / previous["target"])))
        return [*settings_paths, *package_files, runtime.editor_settings_integration_path(root)]
    if target == "zed":
        return [*runtime.zed_paths(), runtime.zed_integration_path(root)]
    if target == "t3code":
        return [*runtime.t3code_paths()[:2], runtime.t3code_integration_path(root)]
    if target == "obsidian":
        from . import obsidian
        try:
            vault = obsidian.safe_paths(obsidian.discover_vault())
        except obsidian.ObsidianFailure as error:
            raise ApplyError(str(error)) from error
        legacy = obsidian._legacy_package_path(vault)
        return [vault.appearance, vault.manifest, vault.stylesheet,
                legacy / "manifest.json", legacy / "theme.css",
                obsidian.obsidian_integration_path(root)]
    return []


def _parent(path: Path, create: bool = False) -> int:
    """Open parents without allowing an external directory link to redirect writes."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in path.parts[1:-1]:
            try:
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(name, 0o700, dir_fd=fd)
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except Exception:
        os.close(fd)
        raise


def capture(target: str) -> dict[str, Any]:
    entries = {}
    directories = {}
    for path in paths(target):
        parent = path.parent
        while parent != parent.parent and not parent.exists():
            directories[str(parent)] = None
            parent = parent.parent
        try:
            fd = _parent(path)
        except FileNotFoundError:
            entries[str(path)] = {"kind": "absent"}
            continue
        try:
            try:
                info = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                entries[str(path)] = {"kind": "absent"}
                continue
            if info.st_uid != os.getuid():
                raise ApplyError(f"target file belongs to another user: {path}")
            if (stat.S_ISLNK(info.st_mode) and target in EDITOR_TARGETS
                    and not (target in ("code", "cursor_editor") and path == runtime.editor_settings_path(target))):
                raise ApplyError(f"refusing symlinked application publication path: {path}")
            if stat.S_ISLNK(info.st_mode):
                entries[str(path)] = {"kind": "symlink", "target": os.readlink(path.name, dir_fd=fd)}
                if target in ("code", "cursor_editor") and path == runtime.editor_settings_path(target):
                    entries[str(path)]["identity"] = [info.st_dev, info.st_ino]
                    parent_info = os.fstat(fd)
                    entries[str(path)]["parentIdentity"] = [parent_info.st_dev, parent_info.st_ino]
            elif stat.S_ISREG(info.st_mode):
                file_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                with os.fdopen(file_fd, "rb") as handle:
                    data = handle.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024:
                    raise ApplyError(f"target file is too large to capture: {path}")
                entries[str(path)] = {"kind": "file", "mode": stat.S_IMODE(info.st_mode),
                                      "bytes": base64.b64encode(data).decode("ascii")}
                if target in ("code", "cursor_editor") and path in _editor_settings_paths(target):
                    parent_info = os.fstat(fd)
                    entries[str(path)]["parentIdentity"] = [parent_info.st_dev, parent_info.st_ino]
            else:
                raise ApplyError(f"unsupported target file: {path}")
        finally:
            os.close(fd)
    image = {"files": entries, "absentDirectories": sorted(directories)}
    if target == "cursor":
        image["cacheKeys"], image["cacheDirectoryExisted"] = _cursor_cache_entries()
    return image


def _valid_identity(value: Any) -> bool:
    return isinstance(value, list) and len(value) == 2 and all(type(item) is int and item >= 0 for item in value)


def validate(target: str, image: Any) -> None:
    keys = {"files", "absentDirectories"}
    if target == "cursor":
        keys |= {"cacheKeys", "cacheDirectoryExisted"}
    if not isinstance(image, dict) or set(image) != keys:
        raise ApplyError("invalid external target pre-image")
    if target == "cursor" and (type(image["cacheDirectoryExisted"]) is not bool
            or not isinstance(image["cacheKeys"], list)
            or any(not isinstance(key, str) or not _CACHE_ENTRY_NAME.fullmatch(key) for key in image["cacheKeys"])):
        raise ApplyError("invalid cursor cache pre-image")
    expected = {str(path) for path in paths(target, image=image)}
    if not isinstance(image["files"], dict) or set(image["files"]) != expected:
        raise ApplyError("external target pre-image paths differ")
    allowed_dirs = {str(parent) for path in paths(target, image=image) for parent in path.parents if parent != Path("/")}
    directories = image["absentDirectories"]
    if not isinstance(directories, list) or any(not isinstance(path, str) or path not in allowed_dirs for path in directories):
        raise ApplyError("invalid target directory pre-image")
    for entry in image["files"].values():
        if not isinstance(entry, dict):
            raise ApplyError("invalid target file pre-image")
        if entry == {"kind": "absent"}:
            continue
        if entry.get("kind") == "symlink" and isinstance(entry.get("target"), str):
            if set(entry) == {"kind", "target"}:
                continue
            identity = entry.get("identity")
            if (set(entry) in ({"kind", "target", "identity"}, {"kind", "target", "identity", "parentIdentity"}) and target in ("code", "cursor_editor")
                    and isinstance(identity, list) and len(identity) == 2
                    and all(type(value) is int and value >= 0 for value in identity)
                    and ("parentIdentity" not in entry or _valid_identity(entry["parentIdentity"]))):
                continue
        if (set(entry) == {"kind", "mode", "bytes"} or
                (set(entry) == {"kind", "mode", "bytes", "parentIdentity"} and target in ("code", "cursor_editor") and _valid_identity(entry["parentIdentity"]))) and entry["kind"] == "file" and type(entry["mode"]) is int and 0 <= entry["mode"] <= 0o7777:
            try:
                base64.b64decode(entry["bytes"], validate=True)
                continue
            except (ValueError, TypeError):
                pass
        raise ApplyError("invalid target file pre-image")


def verify_editor_link(target: str, image: dict[str, Any]) -> None:
    """Never restore through a link changed since the original capture."""
    settings = runtime.editor_settings_path(target)
    expected = image["files"][str(settings)]
    try:
        fd = _parent(settings)
    except FileNotFoundError:
        if expected["kind"] == "absent":
            return
        raise ApplyError("editor settings parent disappeared before restoration")
    try:
        try:
            info = os.stat(settings.name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            if expected["kind"] == "absent":
                return
            raise ApplyError("editor settings link disappeared before restoration")
        if expected["kind"] == "symlink":
            parent = os.fstat(fd)
            if (not stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid()
                    or os.readlink(settings.name, dir_fd=fd) != expected["target"]
                    or ("identity" in expected and [info.st_dev, info.st_ino] != expected["identity"])
                    or ("parentIdentity" in expected and [parent.st_dev, parent.st_ino] != expected["parentIdentity"])):
                raise ApplyError("editor settings link changed before restoration")
        elif stat.S_ISLNK(info.st_mode):
            raise ApplyError("editor settings became a link before restoration")
    finally:
        os.close(fd)
    destination = (Path(os.path.abspath(settings.parent / expected["target"]))
                   if expected["kind"] == "symlink" else settings)
    prior = image["files"][str(destination)]
    if "parentIdentity" in prior:
        try:
            parent_fd = _parent(destination)
            try:
                parent = os.fstat(parent_fd)
                if [parent.st_dev, parent.st_ino] != prior["parentIdentity"]:
                    raise ApplyError("editor settings referent parent changed before restoration")
                referent = os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
                if not stat.S_ISREG(referent.st_mode) or referent.st_uid != os.getuid():
                    raise ApplyError("editor settings referent became unsafe before restoration")
            finally:
                os.close(parent_fd)
        except OSError as error:
            raise ApplyError("editor settings referent parent is unsafe before restoration") from error


def editor_publication_destination(target: str, image: dict[str, Any]) -> tuple[Path, int]:
    """Reject changed capture state before any application package mutation."""
    validate(target, image)
    settings = runtime.editor_settings_path(target)
    before = image["files"][str(settings)]
    destination = (Path(os.path.abspath(settings.parent / before["target"]))
                   if before["kind"] == "symlink" else settings)
    now = capture(target)["files"]
    for path in {settings, destination}:
        if now.get(str(path)) != image["files"][str(path)]:
            raise ApplyError("editor settings changed before publication")
    fd = _parent(destination, create=image["files"][str(destination)]["kind"] == "absent")
    parent = os.fstat(fd)
    expected_parent = image["files"][str(destination)].get("parentIdentity")
    if expected_parent is not None and [parent.st_dev, parent.st_ino] != expected_parent:
        os.close(fd)
        raise ApplyError("editor settings parent changed before publication")
    return destination, fd


def _editor_integration_restore_entry(target: str, previous: dict[str, Any]) -> dict[str, Any]:
    """Restore exact shared bytes unless another editor acquired newer state."""
    current = capture(target)["files"][str(runtime.editor_settings_integration_path(runtime.state_dir()))]
    try:
        before = (json.loads(base64.b64decode(previous["bytes"]))
                  if previous["kind"] == "file" else {"schema_version": 1, "editors": {}})
        now = runtime._load_editor_integration(runtime.state_dir())
        prior_others = {key: value for key, value in before["editors"].items() if key != target}
        current_others = {key: value for key, value in now["editors"].items() if key != target}
    except (ValueError, KeyError, TypeError, runtime.RuntimeFailure) as error:
        raise ApplyError("invalid shared editor integration during restore") from error
    if prior_others == current_others:
        return previous
    if target in before["editors"]:
        now["editors"][target] = before["editors"][target]
    else:
        now["editors"].pop(target, None)
    return {"kind": "file", "mode": current.get("mode", 0o600),
            "bytes": base64.b64encode(json.dumps(now, sort_keys=True, indent=2).encode() + b"\n").decode("ascii")}


def restore(target: str, image: dict[str, Any]) -> None:
    validate(target, image)
    for text, entry in image["files"].items():
        path = Path(text)
        if target in ("code", "cursor_editor") and path == runtime.editor_settings_integration_path(runtime.state_dir()):
            entry = _editor_integration_restore_entry(target, entry)
        try:
            fd = _parent(path, create=entry["kind"] != "absent")
        except FileNotFoundError:
            if entry["kind"] == "absent":
                continue
            raise
        try:
            if (target in ("code", "cursor_editor") and path == runtime.editor_settings_path(target)
                    and entry["kind"] == "symlink"):
                info = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
                if (not stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid()
                        or os.readlink(path.name, dir_fd=fd) != entry["target"]
                        or ("identity" in entry and [info.st_dev, info.st_ino] != entry["identity"])):
                    raise ApplyError("editor settings link changed before restoration")
                continue
            try:
                os.unlink(path.name, dir_fd=fd)
            except FileNotFoundError:
                pass
            if entry["kind"] == "symlink":
                os.symlink(entry["target"], path.name, dir_fd=fd)
            elif entry["kind"] == "file":
                file_fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, entry["mode"], dir_fd=fd)
                with os.fdopen(file_fd, "wb") as handle:
                    handle.write(base64.b64decode(entry["bytes"], validate=True))
                    os.fchmod(handle.fileno(), entry["mode"])
                    os.fsync(handle.fileno())
            os.fsync(fd)
        finally:
            os.close(fd)
    if target == "cursor":
        from .cursor import validate_cursor_cache
        caches = runtime.state_dir() / "cursors"
        if caches.exists():
            for cache in caches.iterdir():
                if cache.name in image["cacheKeys"]:
                    continue
                if cache.is_symlink() or not _CACHE_KEY.fullmatch(cache.name):
                    raise ApplyError("cursor cache needs manual recovery")
                record = json.loads((cache / "cache.json").read_text())
                metadata = record.get("metadata", {})
                if metadata.get("cache_key") != cache.name or not validate_cursor_cache(cache, metadata):
                    raise ApplyError("cursor cache changed before restoration")
                shutil.rmtree(cache)
            if not image["cacheDirectoryExisted"]:
                caches.rmdir()
    for text in sorted(image["absentDirectories"], key=lambda value: len(Path(value).parts), reverse=True):
        try:
            Path(text).rmdir()
        except FileNotFoundError:
            pass
        except OSError:
            # Another target can legitimately share a newly created parent.
            pass
