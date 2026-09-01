"""Manage the small, content-addressed wallpaper library used by the picker."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any

from .core import (
    apply_theme_defaults,
    builtin_themes_dir,
    canonical_json,
    load_json,
    resolve_wallpaper_path,
    themes_dir,
    user_theme_library,
)


MAX_WALLPAPER_BYTES = 48 * 1024 * 1024
SUPPORTED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
_PNG = b"\x89PNG\r\n\x1a\n"
_JPEG = b"\xff\xd8\xff"
_WEBP_PREFIX = b"RIFF"
_WEBP_MARKER = b"WEBP"
_THEME_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")


class WallpaperFailure(ValueError):
    """Report an invalid, unsafe, or in-use wallpaper library operation."""


def _digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def _looks_like_image(path: Path) -> bool:
    if path.suffix.lower() not in SUPPORTED_EXTENSIONS:
        return False
    try:
        with path.open("rb") as handle:
            header = handle.read(16)
    except OSError:
        return False
    if header.startswith(_PNG) or header.startswith(_JPEG):
        return True
    return header.startswith(_WEBP_PREFIX) and header[8:12] == _WEBP_MARKER


def _checked_source(value: str | Path) -> Path:
    source = Path(value).expanduser()
    if source.is_symlink():
        raise WallpaperFailure("wallpaper symlinks are not allowed")
    try:
        source = source.resolve(strict=True)
    except FileNotFoundError as error:
        raise WallpaperFailure(f"wallpaper file not found: {source}") from error
    if not source.is_file():
        raise WallpaperFailure(f"wallpaper is not a regular file: {source}")
    try:
        size = source.stat().st_size
    except OSError as error:
        raise WallpaperFailure(f"could not inspect wallpaper: {error}") from error
    if size > MAX_WALLPAPER_BYTES:
        raise WallpaperFailure(f"wallpaper is larger than {MAX_WALLPAPER_BYTES // (1024 * 1024)} MiB")
    if not _looks_like_image(source):
        raise WallpaperFailure("wallpaper must be a PNG, JPEG, or WebP image")
    return source


def _display_name(stem: str) -> str:
    words = re.sub(r"[_-]+", " ", stem).strip()
    return words.title() if words else "Wallpaper"


def _safe_filename(source: Path) -> str:
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", source.stem).strip(".-") or "wallpaper"
    suffix = source.suffix.lower()
    return f"{stem}{suffix}"


def _metadata_path(image: Path) -> Path:
    return image.with_name(image.name + ".json")


def _write_atomic(path: Path, data: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def _copy_atomic(source: Path, destination: Path) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        with source.open("rb") as source_handle, os.fdopen(descriptor, "wb") as destination_handle:
            shutil.copyfileobj(source_handle, destination_handle, length=1024 * 1024)
            destination_handle.flush()
            os.fsync(destination_handle.fileno())
        os.replace(temporary, destination)
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def _record(
    path: Path,
    kind: str,
    reference: str,
    name: str | None = None,
    removable: bool | None = None,
) -> dict[str, Any]:
    return {
        "id": _digest(path),
        "name": name or _display_name(path.stem),
        "kind": kind,
        "path": str(path),
        "reference": reference,
        "removable": kind == "Imported" if removable is None else removable,
        "missing": False,
        "size": path.stat().st_size,
    }


def _builtin_names() -> dict[Path, str]:
    names: dict[Path, str] = {}
    for source in sorted(builtin_themes_dir().glob("*.json")):
        try:
            theme = apply_theme_defaults(load_json(source))
            wallpaper = theme.get("wallpaper", {}).get("path", "")
            if not wallpaper:
                continue
            resolved = resolve_wallpaper_path(wallpaper, source)
            names[resolved] = str(theme.get("name") or _display_name(resolved.stem))
        except (OSError, ValueError, TypeError, KeyError):
            continue
    return names


def _builtin_reference(path: Path) -> str:
    try:
        return str(path.relative_to(themes_dir()))
    except ValueError:
        return str(Path("wallpapers") / "showcase" / path.name)


def _builtin_roots() -> tuple[Path, ...]:
    """Return read-only package wallpaper roots in scan order."""
    return tuple(themes_dir() / "wallpapers" / name for name in ("showcase", "builtin"))


def _is_builtin_wallpaper(path: Path) -> bool:
    return any(_is_under(path, root) for root in _builtin_roots())


def _user_images() -> list[Path]:
    root = _managed_root()
    if not root.is_dir():
        return []
    return sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink() and path.suffix.lower() in SUPPORTED_EXTENSIONS and _looks_like_image(path)
    )


def _managed_root() -> Path:
    return user_theme_library() / "wallpapers"


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except (OSError, ValueError):
        return False
    return True


def _managed_wallpaper(digest: str) -> Path | None:
    for path in _user_images():
        try:
            if _digest(path) == digest:
                return path
        except OSError:
            continue
    return None


def _copy_to_managed(source: Path, theme_id: str) -> Path:
    """Copy a checked image into the user library, reusing equal bytes."""
    digest = _digest(source)
    existing = _managed_wallpaper(digest)
    if existing:
        return existing

    directory = _managed_root() / theme_id / "wallpaper"
    directory.mkdir(parents=True, exist_ok=True)
    filename = _safe_filename(source)
    destination = directory / filename
    counter = 2
    while destination.exists() or destination.is_symlink():
        destination = directory / f"{Path(filename).stem}-{counter}{Path(filename).suffix}"
        counter += 1
    try:
        _copy_atomic(source, destination)
        _write_atomic(
            _metadata_path(destination),
            json.dumps({"schema_version": 1, "digest": digest, "name": _display_name(source.stem)}, separators=(",", ":")).encode("utf-8"),
        )
    except OSError:
        destination.unlink(missing_ok=True)
        _metadata_path(destination).unlink(missing_ok=True)
        raise
    return destination


def _theme_wallpaper_sources() -> list[tuple[Path, str]]:
    """Find valid external image references left by an incomplete migration."""
    directory = user_theme_library() / "themes"
    if not directory.is_dir():
        return []

    sources: list[tuple[Path, str]] = []
    for source in sorted(directory.glob("*.json")):
        try:
            theme = load_json(source)
            value = theme.get("wallpaper", {}).get("path", "") if isinstance(theme, dict) else ""
            if not isinstance(value, str) or not value:
                continue
            resolved = resolve_wallpaper_path(value, source)
            if resolved.is_file() and not resolved.is_symlink() and not _is_under(resolved, _managed_root()) and not _is_builtin_wallpaper(resolved) and _looks_like_image(resolved):
                sources.append((resolved, value))
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    return sources


def list_wallpapers() -> list[dict[str, Any]]:
    """Return read-only package images and imported user images."""
    records: dict[str, dict[str, Any]] = {}
    names = _builtin_names()
    for builtin_root in _builtin_roots():
        if not builtin_root.is_dir():
            continue
        for path in sorted(builtin_root.iterdir()):
            if not path.is_file() or path.is_symlink() or not _looks_like_image(path):
                continue
            record = _record(path, "Built in", _builtin_reference(path), names.get(path.resolve()))
            records.setdefault(record["id"], record)

    for path in _user_images():
        record = _record(path, "Imported", str(path))
        existing = records.get(record["id"])
        if existing:
            existing.setdefault("origins", [existing["kind"]])
            if "Imported" not in existing["origins"]:
                existing["origins"].append("Imported")
            continue
        metadata = _metadata_path(path)
        if metadata.is_file():
            try:
                document = json.loads(metadata.read_text(encoding="utf-8"))
                if document.get("digest") == record["id"] and document.get("name"):
                    record["name"] = str(document["name"])
            except (OSError, json.JSONDecodeError, AttributeError):
                pass
        records[record["id"]] = record

    for path, reference in _theme_wallpaper_sources():
        record = _record(path, "Imported", reference, removable=False)
        existing = records.get(record["id"])
        if existing:
            existing.setdefault("origins", [existing["kind"]])
            if "Imported" not in existing["origins"]:
                existing["origins"].append("Imported")
            continue
        records[record["id"]] = record

    return sorted(records.values(), key=lambda item: (item["kind"] != "Built in", item["name"].casefold(), item["id"]))


def migrate_theme_wallpapers() -> list[dict[str, Any]]:
    """Adopt old external theme wallpapers into the managed library.

    The source files remain untouched. User themes point at the managed copy
    after this operation, so old and new imports share the same removal rules.
    """
    directory = user_theme_library() / "themes"
    if not directory.is_dir():
        return list_wallpapers()

    for source in sorted(directory.glob("*.json")):
        if source.is_symlink() or not source.is_file():
            continue
        try:
            theme = load_json(source)
            wallpaper = theme.get("wallpaper") if isinstance(theme, dict) else None
            theme_id = theme.get("id") if isinstance(theme, dict) else None
            value = wallpaper.get("path") if isinstance(wallpaper, dict) else ""
            if not isinstance(theme_id, str) or not _THEME_ID.fullmatch(theme_id):
                continue
            if not isinstance(value, str) or not value:
                continue
            resolved = resolve_wallpaper_path(value, source)
            if _is_under(resolved, _managed_root()) or _is_builtin_wallpaper(resolved):
                continue
            checked = _checked_source(resolved)
            managed = _copy_to_managed(checked, theme_id)
            theme["wallpaper"] = dict(wallpaper)
            theme["wallpaper"]["path"] = str(managed)
            _write_atomic(source, canonical_json(theme).encode("utf-8"))
        except (OSError, ValueError, TypeError, AttributeError, WallpaperFailure):
            continue
    return list_wallpapers()


def import_wallpaper(source: str | Path, theme_id: str) -> dict[str, Any]:
    """Copy one image into the importing theme's managed library atomically."""
    if not _THEME_ID.fullmatch(theme_id):
        raise WallpaperFailure("wallpaper imports require a stable theme ID")
    checked = _checked_source(source)
    digest = _digest(checked)
    existing = next((item for item in list_wallpapers() if item["id"] == digest and item["kind"] == "Built in"), None)
    if existing:
        return {**existing, "duplicate": True, "imported": False}

    existing = _managed_wallpaper(digest)
    if existing:
        record = next((item for item in list_wallpapers() if item["id"] == digest and item["kind"] == "Imported"), None)
        return {**(record or _record(existing, "Imported", str(existing))), "duplicate": True, "imported": False}

    destination = _copy_to_managed(checked, theme_id)
    return {**_record(destination, "Imported", str(destination), _display_name(checked.stem)), "duplicate": False, "imported": True}


def _themes_using(paths: set[Path]) -> list[str]:
    directory = user_theme_library() / "themes"
    if not directory.is_dir():
        return []
    users: list[str] = []
    for source in sorted(directory.glob("*.json")):
        try:
            theme = apply_theme_defaults(load_json(source))
            value = theme.get("wallpaper", {}).get("path", "")
            if value and resolve_wallpaper_path(value, source).resolve() in paths:
                users.append(str(theme.get("name") or source.stem))
        except (OSError, ValueError, TypeError, KeyError):
            continue
    return users


def remove_wallpaper(wallpaper_id: str) -> dict[str, Any]:
    """Remove a managed image after proving no saved user theme still uses it."""
    if not _DIGEST.fullmatch(wallpaper_id):
        raise WallpaperFailure("wallpaper ID must be a SHA-256 digest")
    matches = {path for path in _user_images() if _digest(path) == wallpaper_id}
    if not matches:
        raise WallpaperFailure("managed wallpaper not found")
    users = _themes_using(matches)
    if users:
        raise WallpaperFailure("cannot remove a wallpaper used by saved theme(s): " + ", ".join(users))
    for path in matches:
        path.unlink()
        _metadata_path(path).unlink(missing_ok=True)
        parent = path.parent
        if parent.name == "wallpaper" and not any(parent.iterdir()):
            parent.rmdir()
            if not parent.parent.exists() or not any(parent.parent.iterdir()):
                parent.parent.rmdir()
    return {"id": wallpaper_id, "removed": True, "count": len(matches)}
