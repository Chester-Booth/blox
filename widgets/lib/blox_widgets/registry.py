"""Discover explicitly installed, trusted QML packages without loading their code."""

from __future__ import annotations

import json
import os
from pathlib import Path

from .model import ValidationError, validate_settings

MAX_MANIFEST_BYTES = 65536
MAX_PACKAGES = 256


def registry_path() -> Path:
    """Keep executable user packages outside the immutable application tree."""
    fallback = Path.home() / ".local" / "share"
    data_home = Path(os.environ.get("XDG_DATA_HOME") or fallback)
    return (data_home if data_home.is_absolute() else fallback) / "blox-user" / "widgets"


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"manifest: duplicate field {key!r}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValidationError(f"manifest: invalid JSON constant {value}")


def _contained(path: Path, parent: Path) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(parent):
        raise ValidationError(f"{path.name}: path escapes its package directory")
    return resolved


def _package(directory: Path, root: Path) -> tuple[str, dict]:
    package = _contained(directory, root)
    if package == root or not package.is_dir():
        raise ValidationError("package must be a directory below the registry root")
    manifest_path = _contained(package / "widget.json", package)
    source = _contained(package / "Main.qml", package)
    if not manifest_path.is_file() or not source.is_file():
        raise ValidationError("widget.json and Main.qml must be regular files")
    with manifest_path.open("rb") as stream:
        raw = stream.read(MAX_MANIFEST_BYTES + 1)
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ValidationError("manifest: exceeds 64 KiB")
    try:
        manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object,
                              parse_constant=_reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValidationError("manifest: expected UTF-8 JSON object") from error
    fields = {"id", "name", "layouts", "providers"}
    if not isinstance(manifest, dict) or set(manifest) != fields:
        raise ValidationError("manifest: expected exactly id, name, layouts and providers")
    name = manifest["name"]
    if not isinstance(name, str) or not name.strip() or len(name) > 128 or "\0" in name:
        raise ValidationError("manifest.name: expected a nonempty name of at most 128 characters")
    try:
        name.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValidationError("manifest.name: expected valid Unicode") from error
    settings = validate_settings("qml", {"manifest": manifest["id"], "layouts": manifest["layouts"],
                                         "providers": manifest["providers"], "settings": {}})
    return settings["manifest"], {"source": source.as_uri(), "layouts": settings["layouts"],
                                   "providers": settings["providers"], "name": name}


def scan_registry(root: str | Path | None = None) -> dict:
    """Return valid packages and per-package errors. Never import or execute QML.

    Invalid packages do not hide valid ones. Duplicate IDs have no winner. Missing
    roots are an empty registry; root I/O failures and scan limits propagate.
    """
    directory = Path(root) if root is not None else registry_path()
    try:
        resolved_root = directory.resolve(strict=True)
    except FileNotFoundError:
        return {"registry": {}, "errors": []}
    packages = []
    for entry in resolved_root.iterdir():
        if entry.is_dir() or entry.is_symlink():
            packages.append(entry)
            if len(packages) > MAX_PACKAGES:
                raise ValidationError(f"registry: at most {MAX_PACKAGES} package directories are supported")
    registry = {}
    errors = []
    seen = {}
    duplicates = set()
    for package in sorted(packages, key=lambda path: path.name):
        try:
            identity, manifest = _package(package, resolved_root)
            if identity in seen:
                if identity not in duplicates:
                    registry.pop(identity, None)
                    errors.append({"package": str(seen[identity]), "type": "validation",
                                   "message": f"manifest: duplicate id {identity!r}"})
                duplicates.add(identity)
                raise ValidationError(f"manifest: duplicate id {identity!r}")
            seen[identity] = package
            registry[identity] = manifest
        except (ValidationError, OSError) as error:
            errors.append({"package": str(package),
                           "type": "validation" if isinstance(error, ValidationError) else "io",
                           "message": str(error)})
    return {"registry": registry, "errors": errors}
