from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from contextlib import AbstractContextManager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from . import RENDERER_VERSION
from .browser_targets import BROWSER_TARGET_BY_ID, browser_target, detect_browser_target
from .core import DEFAULT_THEME_ID, EDITOR_THEME_PACKAGE_NAME, EDITOR_THEME_PUBLISHER, EDITOR_THEME_RELATIVE_PATH, EDITOR_THEME_VERSION, ZED_THEME_FAMILY_NAME, canonical_json, editor_colours, is_builtin_theme_path, load_theme, render_theme, repository_root, resolve_wallpaper_path, sha256_text, state_dir
from .editor import EditorSettingsFailure, apply_fragment, members, read_settings_values, restore_settings
from .obsidian import ObsidianFailure, needs_reapply as obsidian_needs_reapply, preflight as obsidian_preflight, publish as publish_obsidian_theme, reset as reset_obsidian_theme


TARGET_FILES = {
    "quickshell": ("quickshell/theme.json",),
    "widgets": ("widgets/profile.json",),
    "kitty": ("kitty/theme.conf",),
    "wallpaper": ("hypr/wallpaper.json",),
    "gtk": ("gtk/gtk-3.0/settings.ini", "gtk/gtk-3.0/gtk.css", "gtk/gtk-4.0/settings.ini", "gtk/gtk-4.0/gtk.css", "gtk/metadata.json"),
    "helium": ("helium/manifest.json",),
    "chromium": ("chromium/manifest.json",),
    "cursor": ("cursor/metadata.json",),
    "hyprland": ("hyprland/theme.lua", "hyprland/hyprtoolkit.conf"),
    "hyprlock": ("hyprlock/theme.conf",),
    "btop": ("btop/theme.theme",),
    "micro": ("micro/blox-theme.micro",),
    "glow": ("glow/style.json",),
    "code": ("code/settings.json", "code/package.json", "code/themes/blox-generated-color-theme.json"),
    "cursor_editor": ("cursor-editor/settings.json", "cursor-editor/package.json", "cursor-editor/themes/blox-generated-color-theme.json"),
    "t3code": ("t3code/theme.json",),
    "zed": ("zed/themes/blox-generated.json",),
    "stylus": ("stylus/blox-system.user.css", "stylus/manifest.json"),
    "obsidian": ("obsidian/manifest.json", "obsidian/theme.css"),
    "powerlevel10k": ("powerlevel10k/theme.zsh",),
}
TARGET_REQUIRED_FILES = {
    **{target: files for target, files in TARGET_FILES.items() if target != "gtk"},
    "gtk": ("gtk/gtk-3.0/settings.ini", "gtk/gtk-4.0/settings.ini", "gtk/metadata.json"),
}
# The GTK-owned Helium path is accepted only while an old generation is being
# carried forward. New generations never copy it.
LEGACY_TARGET_FILES = {
    "obsidian/blox-theme.css": "obsidian",
    "obsidian/style-settings.json": "obsidian",
    "gtk/helium/manifest.json": "gtk",
    "code/themes/blox-dark-2026.json": "code",
}
# Chromium writes this cache beside an unpacked theme extension at startup.
RUNTIME_ARTIFACTS = {"helium/Cached Theme.pak", "chromium/Cached Theme.pak"}
TARGET_NAMES = tuple(TARGET_FILES)
GENERATION_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
HISTORY_LIMIT = 5
PHASE7_FALLBACK_TARGETS = ("hyprlock", "btop", "micro", "glow")
EDITOR_SETTING_KEYS = {
    "code": ("workbench.colorTheme", "editor.fontFamily", "workbench.experimental.modernUI"),
    "cursor_editor": ("workbench.colorTheme", "editor.fontFamily"),
}
EDITOR_MODERN_UI_SUPPORT = {"code": True, "cursor_editor": False}
EDITOR_LEGACY_EXTENSION_DIR = "blox.blox-dark-2026-1.0.0"
EDITOR_EXTENSION_DIR = f"{EDITOR_THEME_PUBLISHER}.{EDITOR_THEME_PACKAGE_NAME}-{EDITOR_THEME_VERSION}"
T3CODE_THEME_ID = "blox-theme"
ZED_THEME_WATCH_SETTLE_SECONDS = 0.2


class RuntimeFailure(Exception):
    """A safe, user-facing runtime failure."""


class LockContended(RuntimeFailure):
    """Another mutating theme operation owns the application lock."""


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())


def _atomic_write_text(path: Path, content: str) -> None:
    """Replace a text file without exposing a partial document to its watcher."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        _write_text(temporary, content)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _target_for_file(name: str) -> str | None:
    for target, names in TARGET_FILES.items():
        if name in names:
            return target
    return LEGACY_TARGET_FILES.get(name)


def _target_file_names(target: str) -> tuple[str, ...]:
    names = list(TARGET_FILES[target])
    names.extend(name for name, owner in LEGACY_TARGET_FILES.items() if owner == target)
    return tuple(dict.fromkeys(names))


def _target_signature(path: Path, target: str) -> dict[str, str | None]:
    return {
        name: _file_sha256(path / name) if (path / name).is_file() else None
        for name in _target_file_names(target)
    }


def _target_changed(previous_path: Path | None, previous_manifest: dict[str, Any] | None, candidate: Path, target: str) -> bool:
    if previous_path is None or previous_manifest is None or target not in previous_manifest.get("enabled_targets", []):
        return True
    return _target_signature(previous_path, target) != _target_signature(candidate, target)


def configured_targets(theme: dict[str, Any], requested: str | Iterable[str] | None = None) -> tuple[str, ...]:
    if requested is None:
        return tuple(target for target in TARGET_NAMES if theme["targets"].get(target, False))
    values = requested.split(",") if isinstance(requested, str) else list(requested)
    targets = tuple(dict.fromkeys(value.strip() for value in values if value.strip()))
    if not targets:
        raise RuntimeFailure("at least one target is required")
    unknown = sorted(set(targets) - set(TARGET_NAMES))
    if unknown:
        raise RuntimeFailure(f"unsupported runtime target(s): {', '.join(unknown)}")
    disabled = [target for target in targets if not theme["targets"][target]]
    if disabled:
        raise RuntimeFailure(f"target(s) disabled by theme: {', '.join(disabled)}")
    return targets


class ApplicationLock(AbstractContextManager["ApplicationLock"]):
    def __init__(self, root: Path | None = None) -> None:
        self.root = root or state_dir()
        self.handle: Any = None

    def __enter__(self) -> "ApplicationLock":
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            self.root.chmod(0o700)
        except OSError:
            pass
        lock_path = self.root / "lock"
        self.handle = lock_path.open("a+", encoding="utf-8")
        try:
            os.chmod(lock_path, 0o600)
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self.handle.close()
            self.handle = None
            raise LockContended("another theme operation is already running") from error
        self.handle.seek(0)
        self.handle.truncate()
        self.handle.write(f"pid={os.getpid()}\n")
        self.handle.flush()
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        if self.handle is not None:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()
            self.handle = None


def _generation_path_from_current(root: Path) -> Path | None:
    current = root / "current"
    if not current.is_symlink():
        if current.exists():
            raise RuntimeFailure(f"theme current path is not a symlink: {current}")
        return None
    resolved = current.resolve(strict=True)
    generations = (root / "generations").resolve()
    if resolved.parent != generations or not GENERATION_PATTERN.fullmatch(resolved.name):
        raise RuntimeFailure(f"theme current link escapes the generations directory: {current}")
    return resolved


def validate_generation(path: Path) -> dict[str, Any]:
    if not path.is_dir() or not GENERATION_PATTERN.fullmatch(path.name):
        raise RuntimeFailure(f"invalid generation: {path.name}")
    manifest_path = path / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"cannot read generation manifest: {manifest_path}") from error
    required = {"schema_version", "renderer_version", "generation_id", "created_at", "operation", "source", "source_sha256", "theme_id", "enabled_targets", "target_sources", "files", "derived"}
    allowed = required | {"origin"}
    if not isinstance(manifest, dict) or not required.issubset(manifest) or not set(manifest).issubset(allowed):
        raise RuntimeFailure(f"generation manifest has an invalid structure: {manifest_path}")
    if manifest["schema_version"] != 1 or manifest["generation_id"] != path.name:
        raise RuntimeFailure(f"generation manifest identity mismatch: {manifest_path}")
    try:
        datetime.fromisoformat(manifest["created_at"])
    except (TypeError, ValueError) as error:
        raise RuntimeFailure(f"generation timestamp is invalid: {manifest_path}") from error
    if not isinstance(manifest["renderer_version"], int) or manifest["renderer_version"] < 1:
        raise RuntimeFailure(f"generation renderer version is invalid: {manifest_path}")
    if not isinstance(manifest["operation"], str) or not isinstance(manifest["source"], str) or not isinstance(manifest["theme_id"], str):
        raise RuntimeFailure(f"generation metadata types are invalid: {manifest_path}")
    if not isinstance(manifest["source_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", manifest["source_sha256"]):
        raise RuntimeFailure(f"generation source digest is invalid: {manifest_path}")
    if "origin" in manifest:
        origin = manifest["origin"]
        if (
            not isinstance(origin, dict)
            or set(origin) != {"kind", "theme_id", "fallback"}
            or origin.get("kind") != "builtin"
            or not isinstance(origin.get("theme_id"), str)
            or not isinstance(origin.get("fallback"), bool)
        ):
            raise RuntimeFailure(f"generation origin metadata is invalid: {manifest_path}")
    if not isinstance(manifest["files"], dict) or not isinstance(manifest["enabled_targets"], list) or not isinstance(manifest["target_sources"], dict) or not isinstance(manifest["derived"], dict):
        raise RuntimeFailure(f"generation manifest types are invalid: {manifest_path}")
    if len(set(manifest["enabled_targets"])) != len(manifest["enabled_targets"]) or not set(manifest["enabled_targets"]).issubset(TARGET_FILES):
        raise RuntimeFailure(f"generation targets are invalid: {manifest_path}")
    generation_manifest = path / "manifest.json"
    actual_files = sorted(
        str(item.relative_to(path))
        for item in path.rglob("*")
        if item.is_file() and item != generation_manifest and str(item.relative_to(path)) not in RUNTIME_ARTIFACTS
    )
    if actual_files != sorted(manifest["files"]):
        raise RuntimeFailure(f"generation file list does not match its manifest: {path.name}")
    for name, expected in manifest["files"].items():
        file_path = path / name
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected) or file_path.is_symlink() or _file_sha256(file_path) != expected:
            raise RuntimeFailure(f"generation file digest mismatch: {name}")
        if _target_for_file(name) not in manifest["enabled_targets"]:
            raise RuntimeFailure(f"generation target is not enabled for file: {name}")
    expected_targets = sorted(
        target
        for target, names in TARGET_FILES.items()
        if any((path / name).is_file() for name in names)
        or any(legacy_target == target and (path / legacy_name).is_file() for legacy_name, legacy_target in LEGACY_TARGET_FILES.items())
    )
    if sorted(manifest["enabled_targets"]) != expected_targets or sorted(manifest["target_sources"]) != expected_targets:
        raise RuntimeFailure(f"generation target metadata is inconsistent: {path.name}")
    for target, source in manifest["target_sources"].items():
        if not isinstance(source, dict) or set(source) != {"theme_id", "source", "source_sha256"}:
            raise RuntimeFailure(f"generation target source is invalid: {target}")
        if not isinstance(source["theme_id"], str) or not isinstance(source["source"], str) or not re.fullmatch(r"[0-9a-f]{64}", source["source_sha256"]):
            raise RuntimeFailure(f"generation target source values are invalid: {target}")
    return manifest


def current_generation(root: Path | None = None) -> tuple[Path, dict[str, Any]] | None:
    root = root or state_dir()
    path = _generation_path_from_current(root)
    active = root / "active.json"
    if path is not None and (not active.is_symlink() or os.readlink(active) != "current/manifest.json"):
        raise RuntimeFailure(f"active manifest link is invalid: {active}")
    return (path, validate_generation(path)) if path else None


def _new_generation_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{uuid.uuid4().hex[:8]}"


def _copy_previous(previous: Path | None, candidate: Path) -> None:
    if previous is None:
        return
    for target in TARGET_FILES:
        names = TARGET_FILES[target]
        if target == "code":
            names = (*names, "code/themes/blox-dark-2026.json")
        for name in names:
            source = previous / name
            if source.is_file():
                destination = candidate / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)


def _remove_target(candidate: Path, target: str) -> None:
    names = list(TARGET_FILES[target])
    names.extend(name for name, owner in LEGACY_TARGET_FILES.items() if owner == target)
    for name in names:
        path = candidate / name
        if path.exists():
            path.unlink()
        parent = path.parent
        while parent != candidate and parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
            parent = parent.parent


def _manifest_files(candidate: Path) -> dict[str, str]:
    generation_manifest = candidate / "manifest.json"
    return {str(path.relative_to(candidate)): _file_sha256(path) for path in sorted(candidate.rglob("*")) if path.is_file() and path != generation_manifest}


def _target_sources(previous_manifest: dict[str, Any] | None, selected: Iterable[str], theme_path: Path, theme: dict[str, Any]) -> dict[str, Any]:
    sources = dict(previous_manifest.get("target_sources", {})) if previous_manifest else {}
    source = {
        "theme_id": theme["id"],
        "source": str(theme_path.resolve()),
        "source_sha256": sha256_text(canonical_json(theme)),
    }
    for target in selected:
        sources[target] = source
    return sources


def _origin_metadata(theme_path: Path, theme: dict[str, Any]) -> dict[str, Any]:
    """Record the built-in used by whole-theme reset.

    User themes have no parent field in the v1 source schema, so they use the
    canonical built-in as the documented reset fallback.
    """
    if is_builtin_theme_path(theme_path):
        return {"kind": "builtin", "theme_id": theme["id"], "fallback": False}
    return {"kind": "builtin", "theme_id": DEFAULT_THEME_ID, "fallback": True}


def _switch_generation(root: Path, generation: Path) -> None:
    temporary = root / f".current-{uuid.uuid4().hex}"
    temporary.symlink_to(Path("generations") / generation.name)
    os.replace(temporary, root / "current")
    active = root / "active.json"
    if not active.is_symlink() or os.readlink(active) != "current/manifest.json":
        temporary_active = root / f".active-{uuid.uuid4().hex}"
        temporary_active.symlink_to("current/manifest.json")
        os.replace(temporary_active, active)
    _fsync_directory(root)


def _prune_generations(root: Path, current: Path) -> None:
    generations = []
    for path in (root / "generations").iterdir():
        if path.is_dir() and GENERATION_PATTERN.fullmatch(path.name):
            generations.append(path)
        elif path.name.startswith(".candidate-"):
            shutil.rmtree(path, ignore_errors=True)
    previous = sorted((path for path in generations if path != current), key=lambda item: item.stat().st_mtime_ns, reverse=True)
    for path in previous[HISTORY_LIMIT:]:
        shutil.rmtree(path)


def _command_text(command: list[str]) -> str:
    return " ".join(command)


def _obsidian_failure_warning(warnings: Iterable[str]) -> str | None:
    return next((warning for warning in warnings if warning.startswith("Obsidian theme was not changed:")), None)


def _restore_generation_after_application_failure(
    root: Path,
    previous_path: Path | None,
    previous_manifest: dict[str, Any] | None,
    selected: Iterable[str],
    failed_generation: Path | None = None,
) -> None:
    if previous_path is not None:
        _switch_generation(root, previous_path)
        sync_dynamic_loaders(root, previous_manifest["enabled_targets"] if previous_manifest else (), selected)
    else:
        cleanup_managed_loaders(root)
        (root / "current").unlink(missing_ok=True)
        (root / "active.json").unlink(missing_ok=True)
    if failed_generation is not None:
        shutil.rmtree(failed_generation, ignore_errors=True)


def editor_settings_path(target: str) -> Path:
    if target not in EDITOR_SETTING_KEYS:
        raise RuntimeFailure(f"unsupported editor target: {target}")
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    return config / ("Code/User/settings.json" if target == "code" else "Cursor/User/settings.json")


def editor_extensions_path(target: str) -> Path:
    if target == "code":
        return Path(os.environ.get("VSCODE_EXTENSIONS", Path.home() / ".vscode/extensions")).expanduser()
    if target == "cursor_editor":
        return Path(os.environ.get("CURSOR_EXTENSIONS", Path.home() / ".cursor/extensions")).expanduser()
    raise RuntimeFailure(f"unsupported editor target: {target}")


def editor_modern_ui_supported(target: str) -> bool:
    """Return the known capability without probing or changing editor state."""
    try:
        return EDITOR_MODERN_UI_SUPPORT[target]
    except KeyError as error:
        raise RuntimeFailure(f"unsupported editor target: {target}") from error


def editor_settings_integration_path(root: Path) -> Path:
    return root / "integration/editor-settings.json"


def _empty_editor_integration() -> dict[str, Any]:
    return {"schema_version": 1, "editors": {}}


def _load_editor_integration(root: Path) -> dict[str, Any]:
    path = editor_settings_integration_path(root)
    if not path.is_file():
        return _empty_editor_integration()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"editor settings integration record is invalid: {path}") from error
    if not isinstance(data, dict) or set(data) != {"schema_version", "editors"} or data["schema_version"] != 1 or not isinstance(data["editors"], dict):
        raise RuntimeFailure(f"editor settings integration record is invalid: {path}")
    for target, record in data["editors"].items():
        if target not in EDITOR_SETTING_KEYS or not isinstance(record, dict) or set(record) != {"settings_path", "keys", "last"}:
            raise RuntimeFailure(f"editor settings integration record is invalid: {path}")
        if not isinstance(record["settings_path"], str) or not isinstance(record["keys"], dict) or not isinstance(record["last"], dict):
            raise RuntimeFailure(f"editor settings integration record is invalid: {path}")
        for key, prior in record["keys"].items():
            if key not in EDITOR_SETTING_KEYS[target] or not isinstance(prior, dict) or not isinstance(prior.get("present"), bool):
                raise RuntimeFailure(f"editor settings integration record is invalid: {path}")
            if prior["present"] and "value" not in prior:
                raise RuntimeFailure(f"editor settings integration record is invalid: {path}")
        if not set(record["last"]).issubset(EDITOR_SETTING_KEYS[target]):
            raise RuntimeFailure(f"editor settings integration record is invalid: {path}")
    return data


def _save_editor_integration(root: Path, data: dict[str, Any]) -> None:
    path = editor_settings_integration_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    _write_text(temporary, canonical_json(data))
    os.replace(temporary, path)
    _fsync_directory(path.parent)


def _capture_editor_settings(root: Path, target: str, fragment: dict[str, Any]) -> tuple[Path, dict[str, Any], dict[str, Any]]:
    settings = editor_settings_path(target)
    keys = {key: fragment[key] for key in EDITOR_SETTING_KEYS[target] if key in fragment}
    if not keys:
        raise RuntimeFailure(f"renderer produced no managed settings for {target}")
    data = _load_editor_integration(root)
    record = data["editors"].setdefault(target, {"settings_path": str(settings), "keys": {}, "last": {}})
    current = read_settings_values(settings, tuple(keys))
    for key, value in current.items():
        record["keys"].setdefault(key, value)
    record["settings_path"] = str(settings)
    _save_editor_integration(root, data)
    return settings, data, keys


def _record_editor_settings_applied(root: Path, target: str, data: dict[str, Any], values: dict[str, Any]) -> None:
    data["editors"][target]["last"] = values
    _save_editor_integration(root, data)


def apply_editor_settings(root: Path, target: str, fragment: dict[str, Any]) -> None:
    settings, data, values = _capture_editor_settings(root, target, fragment)
    apply_fragment(settings, values)
    _record_editor_settings_applied(root, target, data, values)


def t3code_base_dir() -> Path:
    """Return the T3Code base directory used by its desktop server."""
    return Path(os.environ.get("T3CODE_HOME", Path.home() / ".t3")).expanduser()


def t3code_paths() -> tuple[Path, Path, Path]:
    base = t3code_base_dir()
    userdata = base / "userdata"
    return userdata / "themes" / f"{T3CODE_THEME_ID}.json", userdata / "settings.json", userdata / "themes"


def t3code_integration_path(root: Path) -> Path:
    return root / "integration/t3code.json"


def _empty_t3code_integration(paths: tuple[Path, Path, Path], settings: dict[str, Any], published_content: str | None) -> dict[str, Any]:
    previous_default = settings.get("defaultTheme")
    previous_set_at = settings.get("defaultThemeSetAt")
    if previous_default is not None and not isinstance(previous_default, str):
        raise RuntimeFailure("T3Code settings defaultTheme is not a string")
    if previous_set_at is not None and not isinstance(previous_set_at, str):
        raise RuntimeFailure("T3Code settings defaultThemeSetAt is not a string")
    return {
        "schema_version": 1,
        "theme_id": T3CODE_THEME_ID,
        "base_dir": str(t3code_base_dir()),
        "published_path": str(paths[0]),
        "settings_path": str(paths[1]),
        "previous_default_theme": previous_default,
        "previous_default_theme_set_at": previous_set_at,
        "previous_published_content": published_content,
        "last_published_sha256": "",
        "last_default_theme_set_at": "",
    }


def _load_t3code_integration(root: Path) -> dict[str, Any] | None:
    path = t3code_integration_path(root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"T3Code integration record is invalid: {path}") from error
    expected = {
        "schema_version", "theme_id", "base_dir", "published_path", "settings_path",
        "previous_default_theme", "previous_default_theme_set_at", "previous_published_content",
        "last_published_sha256", "last_default_theme_set_at",
    }
    if not isinstance(data, dict) or set(data) != expected or data["schema_version"] != 1 or data["theme_id"] != T3CODE_THEME_ID:
        raise RuntimeFailure(f"T3Code integration record is invalid: {path}")
    string_keys = ("base_dir", "published_path", "settings_path", "last_published_sha256", "last_default_theme_set_at")
    if any(not isinstance(data[key], str) for key in string_keys):
        raise RuntimeFailure(f"T3Code integration record is invalid: {path}")
    for key in ("previous_default_theme", "previous_default_theme_set_at"):
        if data[key] is not None and not isinstance(data[key], str):
            raise RuntimeFailure(f"T3Code integration record is invalid: {path}")
    if data["previous_published_content"] is not None and not isinstance(data["previous_published_content"], str):
        raise RuntimeFailure(f"T3Code integration record is invalid: {path}")
    if data["last_published_sha256"] and not re.fullmatch(r"[0-9a-f]{64}", data["last_published_sha256"]):
        raise RuntimeFailure(f"T3Code integration record is invalid: {path}")
    return data


def _save_t3code_integration(root: Path, data: dict[str, Any]) -> None:
    _atomic_write_text(t3code_integration_path(root), canonical_json(data))


def _read_t3code_settings(path: Path) -> tuple[dict[str, Any], bool]:
    if not path.is_file():
        return {}, False
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"T3Code settings are invalid: {path}") from error
    if not isinstance(data, dict):
        raise RuntimeFailure(f"T3Code settings are invalid: {path}")
    return data, True


def _restore_t3code_settings(path: Path, settings: dict[str, Any], existed: bool) -> None:
    if settings or existed:
        _atomic_write_text(path, canonical_json(settings))
    elif path.exists() or path.is_symlink():
        path.unlink()


def _t3code_write_path(path: Path, label: str) -> None:
    if path.is_symlink():
        raise RuntimeFailure(f"refusing to replace symlinked T3Code {label}: {path}")


def _publish_t3code_theme(root: Path) -> None:
    source = root / "current/t3code/theme.json"
    if not source.is_file():
        raise RuntimeFailure(f"generated T3Code theme is missing: {source}")
    published_path, settings_path, _ = t3code_paths()
    _t3code_write_path(published_path, "theme")
    _t3code_write_path(settings_path, "settings")
    settings, settings_existed = _read_t3code_settings(settings_path)
    integration = _load_t3code_integration(root)
    if integration is not None and (
        integration["published_path"] != str(published_path) or integration["settings_path"] != str(settings_path)
    ):
        raise RuntimeFailure("T3Code integration record points to a different base directory")

    previous_published = None
    if published_path.is_file():
        try:
            previous_published = published_path.read_text(encoding="utf-8")
        except OSError as error:
            raise RuntimeFailure(f"could not read the existing T3Code theme: {published_path}") from error
    created_integration = integration is None
    if integration is None:
        integration = _empty_t3code_integration((published_path, settings_path, t3code_paths()[2]), settings, previous_published)
        _save_t3code_integration(root, integration)

    content = source.read_text(encoding="utf-8")
    previous_settings = dict(settings)
    set_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    try:
        _atomic_write_text(published_path, content)
        next_settings = dict(settings)
        next_settings["defaultTheme"] = T3CODE_THEME_ID
        next_settings["defaultThemeSetAt"] = set_at
        _atomic_write_text(settings_path, canonical_json(next_settings))
        integration["last_published_sha256"] = sha256_text(content)
        integration["last_default_theme_set_at"] = set_at
        _save_t3code_integration(root, integration)
    except (OSError, RuntimeFailure):
        try:
            if previous_published is None:
                published_path.unlink(missing_ok=True)
            else:
                _atomic_write_text(published_path, previous_published)
            _restore_t3code_settings(settings_path, previous_settings, settings_existed)
        finally:
            if created_integration:
                t3code_integration_path(root).unlink(missing_ok=True)
        raise


def _reset_t3code_theme(root: Path) -> list[str]:
    integration = _load_t3code_integration(root)
    if integration is None:
        return ["T3Code has no Blox ownership record; its published theme was left untouched"]
    published_path, settings_path, _ = t3code_paths()
    warnings: list[str] = []
    if published_path.is_symlink():
        warnings.append(f"T3Code published theme is a symlink; left untouched: {published_path}")
    elif published_path.is_file():
        if integration["last_published_sha256"] and _file_sha256(published_path) != integration["last_published_sha256"]:
            warnings.append(f"T3Code published theme changed outside Blox; left untouched: {published_path}")
        elif integration["previous_published_content"] is None:
            published_path.unlink()
        else:
            _atomic_write_text(published_path, integration["previous_published_content"])
    elif integration["previous_published_content"] is not None:
        warnings.append(f"T3Code published theme is missing; left untouched: {published_path}")

    if settings_path.is_symlink():
        warnings.append(f"T3Code settings are a symlink; left untouched: {settings_path}")
    else:
        settings, existed = _read_t3code_settings(settings_path)
        owns_default = (
            settings.get("defaultTheme") == T3CODE_THEME_ID
            and settings.get("defaultThemeSetAt") == integration["last_default_theme_set_at"]
        )
        if owns_default:
            previous_default = integration["previous_default_theme"]
            previous_set_at = integration["previous_default_theme_set_at"]
            if previous_default is None:
                settings.pop("defaultTheme", None)
                settings.pop("defaultThemeSetAt", None)
            else:
                settings["defaultTheme"] = previous_default
                if previous_set_at is None:
                    settings.pop("defaultThemeSetAt", None)
                else:
                    settings["defaultThemeSetAt"] = previous_set_at
            _restore_t3code_settings(settings_path, settings, existed)
        else:
            warnings.append("T3Code default theme changed outside Blox; left the current setting untouched")
    if not warnings:
        t3code_integration_path(root).unlink(missing_ok=True)
    return warnings


def zed_config_dir() -> Path:
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    return config / "zed"


def zed_paths() -> tuple[Path, Path]:
    config = zed_config_dir()
    return config / "themes/blox-generated.json", config / "settings.json"


def zed_integration_path(root: Path) -> Path:
    return root / "integration/zed.json"


def _zed_safe_paths() -> tuple[Path, Path]:
    published, settings = zed_paths()
    config = zed_config_dir()
    themes = published.parent
    for path, label in ((config, "config directory"), (themes, "themes directory")):
        if path.is_symlink():
            raise RuntimeFailure(f"refusing to use symlinked Zed {label}: {path}")
        if path.exists() and not path.is_dir():
            raise RuntimeFailure(f"Zed {label} is not a directory: {path}")
    for path, label in ((published, "theme"), (settings, "settings")):
        if path.is_symlink():
            raise RuntimeFailure(f"refusing to replace symlinked Zed {label}: {path}")
        if path.exists() and not path.is_file():
            raise RuntimeFailure(f"Zed {label} is not a regular file: {path}")
    return published, settings


def _empty_zed_integration(
    published: Path,
    settings: Path,
    previous_theme: dict[str, Any],
    settings_existed: bool,
    previous_published_content: str | None,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "published_path": str(published),
        "settings_path": str(settings),
        "previous_theme": previous_theme,
        "previous_settings_existed": settings_existed,
        "previous_published_content": previous_published_content,
        "last_published_sha256": "",
        "last_theme_value": None,
    }


def _load_zed_integration(root: Path) -> dict[str, Any] | None:
    path = zed_integration_path(root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"Zed integration record is invalid: {path}") from error
    expected = {
        "schema_version", "published_path", "settings_path", "previous_theme",
        "previous_settings_existed", "previous_published_content", "last_published_sha256",
        "last_theme_value",
    }
    if not isinstance(data, dict) or set(data) != expected or data["schema_version"] != 1:
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if any(not isinstance(data[key], str) for key in ("published_path", "settings_path", "last_published_sha256")):
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if not isinstance(data["previous_theme"], dict) or not isinstance(data["previous_theme"].get("present"), bool):
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if data["previous_theme"]["present"] and "value" not in data["previous_theme"]:
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if not isinstance(data["previous_settings_existed"], bool):
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if data["previous_published_content"] is not None and not isinstance(data["previous_published_content"], str):
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if data["last_published_sha256"] and not re.fullmatch(r"[0-9a-f]{64}", data["last_published_sha256"]):
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    if data["last_theme_value"] is not None and not isinstance(data["last_theme_value"], (str, dict)):
        raise RuntimeFailure(f"Zed integration record is invalid: {path}")
    return data


def _save_zed_integration(root: Path, data: dict[str, Any]) -> None:
    _atomic_write_text(zed_integration_path(root), canonical_json(data))


def _zed_current_theme_setting(settings: Path) -> dict[str, Any]:
    return read_settings_values(settings, ("theme",))["theme"]


def _zed_next_theme_value(current: dict[str, Any], name: str, appearance: str) -> str | dict[str, Any]:
    if not current["present"]:
        return name
    value = current["value"]
    if isinstance(value, str):
        return name
    if isinstance(value, dict):
        updated = dict(value)
        updated[appearance] = name
        return updated
    raise RuntimeFailure("Zed settings theme must be a string or light/dark object")


def _zed_generated_file(path: Path) -> bool:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return isinstance(document, dict) and document.get("name") == ZED_THEME_FAMILY_NAME


def _publish_zed_theme(root: Path) -> None:
    source = root / "current/zed/themes/blox-generated.json"
    if not source.is_file():
        raise RuntimeFailure(f"generated Zed theme is missing: {source}")
    try:
        document = json.loads(source.read_text(encoding="utf-8"))
        theme_name = document["themes"][0]["name"]
    except (OSError, json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
        raise RuntimeFailure(f"generated Zed theme is invalid: {source}") from error
    if not isinstance(theme_name, str):
        raise RuntimeFailure(f"generated Zed theme has no selectable theme name: {source}")
    if not (shutil.which("zeditor") or shutil.which("zed")):
        raise RuntimeFailure("Zed is not installed; install the zeditor CLI before applying the Zed target")

    published, settings = _zed_safe_paths()
    current = _zed_current_theme_setting(settings)
    integration = _load_zed_integration(root)
    if integration is not None and (
        integration["published_path"] != str(published) or integration["settings_path"] != str(settings)
    ):
        raise RuntimeFailure("Zed integration record points to a different config directory")
    previous_published = published.read_text(encoding="utf-8") if published.is_file() else None
    if integration is not None and previous_published is not None and integration["last_published_sha256"]:
        if _file_sha256(published) != integration["last_published_sha256"]:
            raise RuntimeFailure(f"refusing to replace Zed theme changed outside Blox: {published}")
    if integration is None and previous_published is not None and not _zed_generated_file(published):
        raise RuntimeFailure(f"refusing to replace foreign Zed theme: {published}")

    created_integration = integration is None
    if integration is None:
        integration = _empty_zed_integration(
            published,
            settings,
            current,
            settings.is_file(),
            previous_published,
        )
        _save_zed_integration(root, integration)

    next_value = _zed_next_theme_value(current, theme_name, document["themes"][0]["appearance"])
    settings_existed = settings.is_file()
    try:
        content = source.read_text(encoding="utf-8")
        _atomic_write_text(published, content)
        # The atomic rename protects readers from a partial JSON document,
        # but some Linux file-watch events report only the temporary path.
        # Touch the completed destination so Zed receives a second event for
        # the path it actually loads.
        os.utime(published, None)
        # Zed polls the themes directory on a short debounce timer. Give it
        # time to register a newly published theme before selecting its name
        # in settings, otherwise the settings watcher can win the race and
        # leave an existing window on the previous theme.
        time.sleep(ZED_THEME_WATCH_SETTLE_SECONDS)
        # Zed 1.17 watches the settings file inode, so preserve it for live
        # theme changes in an existing Zed process.
        apply_fragment(settings, {"theme": next_value}, atomic=False)
        integration["last_published_sha256"] = sha256_text(content)
        integration["last_theme_value"] = next_value
        _save_zed_integration(root, integration)
    except (OSError, EditorSettingsFailure, RuntimeFailure):
        try:
            if previous_published is None:
                published.unlink(missing_ok=True)
            else:
                _atomic_write_text(published, previous_published)
            if current["present"]:
                restore_settings(settings, {"theme": current["value"]}, atomic=False)
            else:
                restore_settings(settings, {}, ("theme",), atomic=False)
            if not settings_existed and settings.is_file():
                parsed, _ = members(settings.read_text(encoding="utf-8"))
                if not parsed:
                    settings.unlink()
        finally:
            if created_integration:
                zed_integration_path(root).unlink(missing_ok=True)
        raise


def _reset_zed_theme(root: Path) -> list[str]:
    integration = _load_zed_integration(root)
    if integration is None:
        return ["Zed has no Blox ownership record; its local theme and settings were left untouched"]
    published, settings = _zed_safe_paths()
    if integration["published_path"] != str(published) or integration["settings_path"] != str(settings):
        raise RuntimeFailure("Zed integration record points to a different config directory")
    warnings: list[str] = []

    # Zed watches the settings file and the user theme directory separately.
    # Restore the selected theme while the generated theme still exists, then
    # remove Blox's file. Removing the active theme first can leave an open
    # Zed window using the old theme until it restarts.
    current = _zed_current_theme_setting(settings)
    setting_owned = integration["last_theme_value"] is not None and _setting_matches(current, integration["last_theme_value"])
    if not setting_owned:
        warnings.append("Zed theme setting changed outside Blox; left the current setting untouched")
    else:
        previous = integration["previous_theme"]
        if previous["present"]:
            restore_settings(settings, {"theme": previous["value"]}, atomic=False)
        else:
            restore_settings(settings, {}, ("theme",), atomic=False)
        if not integration["previous_settings_existed"] and settings.is_file():
            parsed, _ = members(settings.read_text(encoding="utf-8"))
            if not parsed:
                settings.unlink()

    if published.is_file():
        if not integration["last_published_sha256"] or _file_sha256(published) != integration["last_published_sha256"]:
            warnings.append(f"Zed theme changed outside Blox; left untouched: {published}")
        elif integration["previous_published_content"] is None:
            published.unlink()
        else:
            _atomic_write_text(published, integration["previous_published_content"])
    elif integration["previous_published_content"] is not None:
        warnings.append(f"Zed theme is missing; left untouched: {published}")
    if not warnings:
        zed_integration_path(root).unlink(missing_ok=True)
    return warnings


def _setting_matches(value: dict[str, Any], expected: Any) -> bool:
    return value.get("present") is True and value.get("value") == expected


def migrate_legacy_editor_customizations(settings: Path, legacy_theme: dict[str, Any]) -> bool:
    """Drop only old Blox colour overrides so the packaged theme can win."""
    values = read_settings_values(settings, ("workbench.colorCustomizations",))
    current = values["workbench.colorCustomizations"]
    if not current.get("present") or not isinstance(current.get("value"), dict):
        return False
    legacy = editor_colours(legacy_theme)
    cleaned = {
        key: value
        for key, value in current["value"].items()
        if legacy.get(key) != value
    }
    if cleaned == current["value"]:
        return False
    if cleaned:
        restore_settings(settings, {"workbench.colorCustomizations": cleaned})
    else:
        restore_settings(settings, {}, ("workbench.colorCustomizations",))
    return True


def reset_editor_settings(root: Path, target: str) -> list[str]:
    data = _load_editor_integration(root)
    record = data["editors"].get(target)
    if record is None:
        return []
    settings = editor_settings_path(target)
    last = record["last"]
    current = read_settings_values(settings, tuple(last)) if last else {}
    restore: dict[str, Any] = {}
    remove: list[str] = []
    warnings: list[str] = []
    for key, expected in last.items():
        if not _setting_matches(current[key], expected):
            warnings.append(f"preserved user-edited {target} setting: {key}")
            continue
        prior = record["keys"][key]
        if prior["present"]:
            restore[key] = prior["value"]
        else:
            remove.append(key)
    if restore or remove:
        restore_settings(settings, restore, remove)
    del data["editors"][target]
    _save_editor_integration(root, data)
    return warnings


def _editor_package_source(root: Path, target: str) -> Path:
    directory = "code" if target == "code" else "cursor-editor" if target == "cursor_editor" else ""
    if not directory:
        raise RuntimeFailure(f"unsupported editor target: {target}")
    return root / "current" / directory


def _editor_package_manifest(path: Path) -> dict[str, Any]:
    try:
        package = json.loads((path / "package.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"editor theme package is invalid: {path / 'package.json'}") from error
    if not isinstance(package, dict) or package.get("name") != EDITOR_THEME_PACKAGE_NAME or package.get("publisher") != EDITOR_THEME_PUBLISHER or package.get("version") != EDITOR_THEME_VERSION:
        raise RuntimeFailure(f"editor theme package has the wrong identity: {path / 'package.json'}")
    return package


def _copy_fsynced(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as source_handle, destination.open("xb") as destination_handle:
        shutil.copyfileobj(source_handle, destination_handle)
        destination_handle.flush()
        os.fsync(destination_handle.fileno())


def _remove_legacy_editor_extension(extension_root: Path) -> list[str]:
    legacy = extension_root / EDITOR_LEGACY_EXTENSION_DIR
    if not legacy.exists() and not legacy.is_symlink():
        return []
    if legacy.is_symlink():
        return [f"left unexpected legacy editor extension symlink in place: {legacy}"]
    if not legacy.is_dir():
        return [f"left unexpected legacy editor extension in place: {legacy}"]
    try:
        package = json.loads((legacy / "package.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return [f"left legacy editor extension with unreadable manifest in place: {legacy}"]
    if not isinstance(package, dict) or package.get("name") != "blox-dark-2026" or package.get("publisher") != EDITOR_THEME_PUBLISHER:
        return [f"left foreign editor extension in place: {legacy}"]
    shutil.rmtree(legacy)
    return []


def install_editor_extension(root: Path, target: str) -> list[str]:
    source = _editor_package_source(root, target)
    _editor_package_manifest(source)
    theme_source = source / EDITOR_THEME_RELATIVE_PATH
    if not theme_source.is_file():
        raise RuntimeFailure(f"editor theme package is missing: {theme_source}")
    extension_root = editor_extensions_path(target)
    if extension_root.exists() and not extension_root.is_dir():
        raise RuntimeFailure(f"editor extension directory is not a directory: {extension_root}")
    extension_root.mkdir(parents=True, exist_ok=True)
    destination = extension_root / EDITOR_EXTENSION_DIR
    if destination.is_symlink():
        raise RuntimeFailure(f"refusing to replace symlinked editor extension: {destination}")
    if destination.exists() and not destination.is_dir():
        raise RuntimeFailure(f"refusing to replace non-directory editor extension: {destination}")
    if destination.is_dir():
        _editor_package_manifest(destination)
    temporary = extension_root / f".{EDITOR_EXTENSION_DIR}.{uuid.uuid4().hex}.tmp"
    backup = extension_root / f".{EDITOR_EXTENSION_DIR}.{uuid.uuid4().hex}.old"
    temporary.mkdir(mode=0o700)
    try:
        _copy_fsynced(source / "package.json", temporary / "package.json")
        _copy_fsynced(theme_source, temporary / EDITOR_THEME_RELATIVE_PATH)
        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(temporary, destination)
        except Exception:
            if backup.exists() and not destination.exists():
                os.replace(backup, destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
    return _remove_legacy_editor_extension(extension_root)


def remove_editor_extension(target: str) -> None:
    extension_root = editor_extensions_path(target)
    destination = extension_root / EDITOR_EXTENSION_DIR
    if not destination.exists() and not destination.is_symlink():
        return
    if destination.is_symlink():
        raise RuntimeFailure(f"refusing to remove symlinked editor extension: {destination}")
    if not destination.is_dir():
        raise RuntimeFailure(f"refusing to remove non-directory editor extension: {destination}")
    _editor_package_manifest(destination)
    shutil.rmtree(destination)


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        environment = None
        if command and Path(command[0]).name == "obsidian":
            # The shell can export this for Electron-based tools. Obsidian's
            # wrapper interprets it as a request to run as plain Node and then
            # fails before it reaches the official CLI.
            environment = os.environ.copy()
            environment.pop("ELECTRON_RUN_AS_NODE", None)
        return subprocess.run(command, check=False, capture_output=True, text=True, env=environment)
    except OSError as error:
        return subprocess.CompletedProcess(command, 127, "", str(error))


def _proc_main_pid() -> int:
    try:
        completed = subprocess.run(
            ["systemctl", "--user", "show", "-p", "MainPID", "--value", "quickshell.service"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        return int((completed.stdout or "0").strip() or 0)
    except (OSError, ValueError):
        return 0


def _pid_shell_path(pid: int, read_cmdline: Callable[[int], list[str]] | None = None) -> Path | None:
    reader = read_cmdline or (lambda p: open(f"/proc/{p}/cmdline", "rb").read().decode().split("\0"))
    try:
        argv = reader(pid)
    except (OSError, UnicodeDecodeError):
        return None
    if "--path" in argv:
        candidate = Path(argv[argv.index("--path") + 1])
        if candidate.is_dir():
            return candidate
    return None


def quickshell_config_path(read_cmdline: Callable[[int], list[str]] | None = None) -> Path:
    """Locate the RUNNING shell so reload and widget IPC reach it.

    Preference order: an explicit BLOX_SHELL_DIR override, the supervised
    service's own --path argument, the checkout location under
    XDG_CONFIG_HOME when present, otherwise the installed tree."""
    home = Path.home()
    prefix_default = home / ".local"
    override = os.environ.get("BLOX_SHELL_DIR")
    if override:
        return Path(override).expanduser()
    main_pid = _proc_main_pid()
    if main_pid > 0:
        running = _pid_shell_path(main_pid, read_cmdline)
        if running is not None:
            return running
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    legacy = config_home / "quickshell/blox"
    if (legacy / "shell.qml").is_file():
        return legacy
    installed = Path(os.environ.get("BLOX_PREFIX", home)).expanduser() / "share/blox/shell"
    return installed


def _ipc_script() -> Path:
    return repository_root() / "shell/scripts/ipc.sh"


def _ipc_command(*arguments: str) -> list[str]:
    """Address the RUNNING shell by its supervised PID, never by a path."""
    return ["bash", str(_ipc_script()), *arguments]


def kitty_config_path() -> Path:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    return config_home / "kitty/kitty.conf"


def kitty_include_line() -> str:
    return "globinclude blox-theme.conf"


def gtk_config_path(version: str) -> Path:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    return config_home / f"gtk-{version}.0"


def gtk_source_path(version: str, name: str) -> Path:
    return repository_root() / f"gtk/.config/gtk-{version}.0/{name}"


def gtk_integration_path(root: Path) -> Path:
    return root / "integration/gtk-loaders.json"


def cursor_icon_link() -> Path:
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()
    return data_home / f"icons/blox-generated"


def cursor_integration_path(root: Path) -> Path:
    return root / "integration/cursor.json"


def _load_cursor_integration(root: Path) -> dict[str, Any] | None:
    path = cursor_integration_path(root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"cursor integration record is invalid: {path}") from error
    if not isinstance(data, dict) or set(data) != {"schema_version", "fallback"} or data["schema_version"] != 1:
        raise RuntimeFailure(f"cursor integration record is invalid: {path}")
    fallback = data["fallback"]
    if not isinstance(fallback, dict) or set(fallback) != {"theme_name", "size"} or not isinstance(fallback["theme_name"], str) or not isinstance(fallback["size"], int):
        raise RuntimeFailure(f"cursor integration record is invalid: {path}")
    return data


def _gsettings_value(result: subprocess.CompletedProcess[str], default: str) -> str:
    if result.returncode:
        return default
    value = result.stdout.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    return value or default


def _ensure_cursor_integration(root: Path, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]]) -> dict[str, Any]:
    integration = _load_cursor_integration(root)
    if integration is not None:
        return integration
    theme_result = run_command(["gsettings", "get", "org.gnome.desktop.interface", "cursor-theme"])
    size_result = run_command(["gsettings", "get", "org.gnome.desktop.interface", "cursor-size"])
    theme_name = _gsettings_value(theme_result, os.environ.get("XCURSOR_THEME", "Bibata-Modern-Classic"))
    raw_size = _gsettings_value(size_result, os.environ.get("XCURSOR_SIZE", "24"))
    try:
        size = int(raw_size)
    except ValueError:
        size = 24
    integration = {"schema_version": 1, "fallback": {"theme_name": theme_name, "size": size}}
    path = cursor_integration_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    _write_text(temporary, canonical_json(integration))
    os.replace(temporary, path)
    _fsync_directory(path.parent)
    return integration


def setup_cursor(run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run) -> dict[str, Any]:
    from .cursor import CursorFailure, setup_toolchain

    root = state_dir()
    with ApplicationLock(root):
        try:
            toolchain = setup_toolchain()
        except CursorFailure as error:
            raise RuntimeFailure(str(error)) from error
        integration = _ensure_cursor_integration(root, run_command)
        return {"toolchain": toolchain, "integration": integration}


def _cursor_metadata(root: Path) -> dict[str, Any]:
    path = root / "current/cursor/metadata.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"cursor metadata is invalid: {path}") from error
    if not isinstance(data, dict) or data.get("mode") not in ("generated", "installed") or not isinstance(data.get("theme_name"), str) or not isinstance(data.get("size"), int):
        raise RuntimeFailure(f"cursor metadata is invalid: {path}")
    if data["mode"] == "generated" and not isinstance(data.get("cache_key"), str):
        raise RuntimeFailure(f"cursor metadata is invalid: {path}")
    return data


def _managed_cursor_target(target: str, root: Path) -> bool:
    path = Path(target)
    try:
        return path.parent.parent == root / "cursors" and path.name == "theme"
    except (OSError, RuntimeError):
        return False


def ensure_cursor_loader(root: Path, active: bool) -> None:
    link = cursor_icon_link()
    metadata = _cursor_metadata(root) if active else None
    generated = bool(metadata and metadata["mode"] == "generated")
    if generated:
        expected = root / f"cursors/{metadata['cache_key']}/theme"
        if not expected.is_dir():
            raise RuntimeFailure(f"generated cursor cache is missing: {expected}")
        if link.is_symlink() and os.readlink(link) == str(expected):
            return
        if link.is_symlink() and not _managed_cursor_target(os.readlink(link), root):
            raise RuntimeFailure(f"refusing to replace unexpected cursor link: {link}")
        if link.exists() and not link.is_symlink():
            raise RuntimeFailure(f"refusing to replace conflicting cursor theme: {link}")
        link.parent.mkdir(parents=True, exist_ok=True)
        temporary = link.parent / f".{link.name}.{uuid.uuid4().hex}.tmp"
        temporary.symlink_to(expected)
        os.replace(temporary, link)
    elif link.is_symlink() and _managed_cursor_target(os.readlink(link), root):
        link.unlink()


def _load_gtk_integration(root: Path) -> dict[str, Any] | None:
    path = gtk_integration_path(root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"GTK loader integration record is invalid: {path}") from error
    if not isinstance(data, dict) or set(data) != {"schema_version", "loaders"} or data["schema_version"] != 1:
        raise RuntimeFailure(f"GTK loader integration record is invalid: {path}")
    if not isinstance(data["loaders"], dict) or set(data["loaders"]) != {"3", "4"}:
        raise RuntimeFailure(f"GTK loader integration record is invalid: {path}")
    for version in ("3", "4"):
        entries = data["loaders"][version]
        if not isinstance(entries, dict) or set(entries) != {"gtk.css", "gtk-dark.css"}:
            raise RuntimeFailure(f"GTK loader integration record is invalid: {path}")
        for entry in entries.values():
            if not isinstance(entry, dict) or entry.get("kind") not in ("absent", "symlink"):
                raise RuntimeFailure(f"GTK loader integration record is invalid: {path}")
            if entry["kind"] == "symlink" and (set(entry) != {"kind", "target"} or not isinstance(entry["target"], str)):
                raise RuntimeFailure(f"GTK loader integration record is invalid: {path}")
            if entry["kind"] == "absent" and set(entry) != {"kind"}:
                raise RuntimeFailure(f"GTK loader integration record is invalid: {path}")
    return data


def _capture_gtk_integration() -> dict[str, Any]:
    loaders: dict[str, Any] = {}
    for version in ("3", "4"):
        entries = {}
        for name in ("gtk.css", "gtk-dark.css"):
            path = gtk_config_path(version) / name
            if path.is_symlink():
                entries[name] = {"kind": "symlink", "target": os.readlink(path)}
            elif path.exists():
                raise RuntimeFailure(f"refusing to replace regular GTK stylesheet: {path}")
            else:
                entries[name] = {"kind": "absent"}
        loaders[version] = entries
    return {"schema_version": 1, "loaders": loaders}


def _save_gtk_integration(root: Path, data: dict[str, Any]) -> None:
    path = gtk_integration_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    _write_text(temporary, canonical_json(data))
    os.replace(temporary, path)
    _fsync_directory(path.parent)


def _ensure_gtk_integration(root: Path, allow_existing: bool) -> dict[str, Any]:
    existing = _load_gtk_integration(root)
    if existing:
        return existing
    captured = _capture_gtk_integration()
    has_existing = any(entry["kind"] != "absent" for entries in captured["loaders"].values() for entry in entries.values())
    if has_existing and not allow_existing:
        raise RuntimeFailure("existing GTK stylesheet loaders require explicit migration; run: themectl setup gtk --yes")
    _save_gtk_integration(root, captured)
    return captured


def kitty_theme_link() -> Path:
    return kitty_config_path().parent / "blox-theme.conf"


def phase7_loader_specs(root: Path) -> dict[str, tuple[Path, Path]]:
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return {
        "hyprland": (config / "hypr/blox-theme.lua", root / "current/hyprland/theme.lua"),
        "hyprlock": (config / "hypr/blox-theme.conf", root / "current/hyprlock/theme.conf"),
        "btop": (config / "btop/themes/blox-theme.theme", root / "current/btop/theme.theme"),
        "micro": (config / "micro/colorschemes/blox-theme.micro", root / "current/micro/blox-theme.micro"),
        "glow": (config / "glow/blox-theme.json", root / "current/glow/style.json"),
        "powerlevel10k": (config / "blox-theme/powerlevel10k.zsh", root / "current/powerlevel10k/theme.zsh"),
    }


def hyprtoolkit_theme_link() -> Path:
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return config / "hypr/hyprtoolkit.conf"


def _sync_hyprtoolkit_loader(root: Path, active: bool) -> None:
    link = hyprtoolkit_theme_link()
    expected = root / "current/hyprland/hyprtoolkit.conf"
    active = active and expected.is_file()
    if active:
        if link.is_symlink() and os.readlink(link) == str(expected):
            return
        if link.exists() or link.is_symlink():
            raise RuntimeFailure(f"refusing to replace conflicting Hyprtoolkit theme config: {link}")
        link.parent.mkdir(parents=True, exist_ok=True)
        temporary = link.parent / f".{link.name}.{uuid.uuid4().hex}.tmp"
        temporary.symlink_to(expected)
        os.replace(temporary, link)
    elif link.is_symlink() and os.readlink(link) == str(expected):
        link.unlink()


def _phase7_fallback(root: Path, target: str) -> Path:
    fallback = root / "integration/phase7-fallbacks" / TARGET_FILES[target][0]
    if fallback.is_file():
        return fallback
    try:
        source, theme = load_theme(DEFAULT_THEME_ID)
        files, _ = render_theme(theme, source)
        content = files[TARGET_FILES[target][0]]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise RuntimeFailure(f"cannot prepare the {target} reset fallback: {error}") from error
    temporary = fallback.parent / f".{fallback.name}.{uuid.uuid4().hex}.tmp"
    temporary.parent.mkdir(parents=True, exist_ok=True)
    _write_text(temporary, content)
    os.replace(temporary, fallback)
    _fsync_directory(fallback.parent)
    return fallback


def ensure_phase7_loader(root: Path, target: str, active: bool) -> None:
    link, generated = phase7_loader_specs(root)[target]
    expected = generated if active else _phase7_fallback(root, target) if target in PHASE7_FALLBACK_TARGETS else None
    managed = {str(generated)}
    if target in PHASE7_FALLBACK_TARGETS:
        managed.add(str(root / "integration/phase7-fallbacks" / TARGET_FILES[target][0]))
    if expected is None:
        if link.is_symlink() and os.readlink(link) in managed:
            link.unlink()
        return
    if link.is_symlink() and os.readlink(link) == str(expected):
        return
    if (link.exists() and not link.is_symlink()) or (link.is_symlink() and os.readlink(link) not in managed):
        raise RuntimeFailure(f"refusing to replace conflicting {target} theme loader: {link}")
    link.parent.mkdir(parents=True, exist_ok=True)
    temporary = link.parent / f".{link.name}.{uuid.uuid4().hex}.tmp"
    temporary.symlink_to(expected)
    os.replace(temporary, link)


def remove_phase7_loader(root: Path, target: str) -> None:
    link, generated = phase7_loader_specs(root)[target]
    managed = {str(generated)}
    if target in PHASE7_FALLBACK_TARGETS:
        managed.add(str(root / "integration/phase7-fallbacks" / TARGET_FILES[target][0]))
    if link.is_symlink() and os.readlink(link) in managed:
        link.unlink()


def ensure_kitty_loader(root: Path) -> None:
    link = kitty_theme_link()
    expected = root / "current/kitty/theme.conf"
    if link.is_symlink() and Path(os.readlink(link)) == expected:
        return
    if link.exists() or link.is_symlink():
        raise RuntimeFailure(f"refusing to replace conflicting Kitty theme loader: {link}")
    link.parent.mkdir(parents=True, exist_ok=True)
    temporary = link.parent / f".{link.name}.{uuid.uuid4().hex}.tmp"
    temporary.symlink_to(expected)
    os.replace(temporary, link)


def _link_target_path(link: Path, target: str) -> Path:
    path = Path(target)
    return path if path.is_absolute() else link.parent / path


def _same_file_content(first: Path, second: Path) -> bool:
    try:
        return first.is_file() and second.is_file() and _file_sha256(first) == _file_sha256(second)
    except OSError:
        return False


def _replace_known_symlink(
    link: Path,
    expected: Path,
    allowed: Iterable[Path],
    adopt_existing_file: bool = False,
    allow_matching_content: Path | None = None,
) -> None:
    allowed_targets = {str(path) for path in allowed}
    if link.is_symlink():
        current = os.readlink(link)
        if current == str(expected):
            return
        # A drifted link that still resolves to a real stylesheet can be
        # adopted instead of refused (its content is preserved on disk and
        # the swap is recorded by the caller's own flow).
        if current not in allowed_targets:
            current_path = _link_target_path(link, current)
            matching_content = allow_matching_content is not None and _same_file_content(current_path, allow_matching_content)
            adoptable_file = adopt_existing_file and current_path.is_file()
            if not (matching_content or adoptable_file):
                raise RuntimeFailure(f"refusing to replace unexpected theme loader: {link}")
    elif link.exists():
        raise RuntimeFailure(f"refusing to replace conflicting theme loader: {link}")
    link.parent.mkdir(parents=True, exist_ok=True)
    temporary = link.parent / f".{link.name}.{uuid.uuid4().hex}.tmp"
    temporary.symlink_to(expected)
    os.replace(temporary, link)


def _gtk_metadata(root: Path) -> dict[str, Any]:
    path = root / "current/gtk/metadata.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeFailure(f"GTK metadata is invalid: {path}") from error
    if not isinstance(data, dict) or data.get("mode") not in ("generated", "installed") or not isinstance(data.get("generated_css"), bool):
        raise RuntimeFailure(f"GTK metadata is invalid: {path}")
    return data


def ensure_gtk_loaders(root: Path, active: bool) -> None:
    integration = _ensure_gtk_integration(root, allow_existing=False)
    metadata = _gtk_metadata(root) if active else None
    for version in ("3", "4"):
        config = gtk_config_path(version)
        source_settings = gtk_source_path(version, "settings.ini")
        live_settings = config / "settings.ini"
        generated_settings = root / f"current/gtk/gtk-{version}.0/settings.ini"
        generated_css = root / f"current/gtk/gtk-{version}.0/gtk.css"

        settings_target = generated_settings if active else source_settings
        _replace_known_symlink(live_settings, settings_target, (source_settings, generated_settings))
        for dark, loader_name, dynamic_name in ((False, "gtk.css", "blox-theme.css"), (True, "gtk-dark.css", "blox-theme-dark.css")):
            source_loader = gtk_source_path(version, loader_name)
            live_loader = config / loader_name
            entry = integration["loaders"][version][loader_name]
            original = Path(entry["target"]) if entry["kind"] == "symlink" else gtk_source_path(version, "blox-theme-empty-dark.css" if dark else "blox-theme-empty.css")
            allowed_loaders = [source_loader]
            if entry["kind"] == "symlink":
                allowed_loaders.append(Path(entry["target"]))
            _replace_known_symlink(
                live_loader,
                source_loader,
                allowed_loaders,
                allow_matching_content=source_loader,
            )
            dynamic_css = config / dynamic_name
            css_target = generated_css if active and metadata and metadata["generated_css"] else original
            # The neutral empty stylesheet is a legal prior state too (an
            # earlier inactive generation may have written it), so replacing
            # it must not refuse even though it is not the recorded target.
            empty_original = gtk_source_path(version, "blox-theme-empty-dark.css" if dark else "blox-theme-empty.css")
            _replace_known_symlink(dynamic_css, css_target, (original, generated_css, empty_original), adopt_existing_file=True)


def setup_gtk() -> dict[str, Any]:
    root = state_dir()
    with ApplicationLock(root):
        integration = _ensure_gtk_integration(root, allow_existing=True)
        changed = False
        for version in ("3", "4"):
            config = gtk_config_path(version)
            for name, entry in list(integration["loaders"][version].items()):
                # Snapshot whatever is actually live when it differs from
                # the record (for example after the product repository moved):
                # rollback must restore the immediate prior state. Broken
                # symlinks keep their existing record so the discard flow
                # can clean them up.
                live = config / name
                if live.is_symlink() and live.exists():
                    actual = os.readlink(live)
                    if entry.get("target") != actual or entry.get("kind") == "absent":
                        integration["loaders"][version][name] = {"kind": "symlink", "target": actual}
                        _save_gtk_integration(root, integration)
                        changed = True
                    # Adoption: a loader slot recorded as absent may hold a
                    # foreign symlink now (for example one into a personal
                    # checkout). Record it before replacing so rollback can
                    # restore the exact prior state.
                    live = config / name
                    if live.is_symlink():
                        foreign = os.readlink(live)
                        resolved = Path(foreign) if Path(foreign).is_absolute() else config / foreign
                        if resolved.exists():
                            integration["loaders"][version][name] = {"kind": "symlink", "target": foreign}
                            _save_gtk_integration(root, integration)
                            entry = integration["loaders"][version][name]
                        else:
                            continue
                    else:
                        continue
                if entry["kind"] != "symlink":
                    continue
                target = Path(entry["target"])
                resolved = target if target.is_absolute() else config / target
                if not resolved.exists():
                    _replace_known_symlink(config / name, gtk_source_path(version, name), (target, gtk_source_path(version, name)))
                    integration["loaders"][version][name] = {"kind": "absent"}
                    changed = True
        if changed:
            _save_gtk_integration(root, integration)
        for version in ("3", "4"):
            config = gtk_config_path(version)
            for dark, loader_name, dynamic_name in ((False, "gtk.css", "blox-theme.css"), (True, "gtk-dark.css", "blox-theme-dark.css")):
                if integration["loaders"][version][loader_name]["kind"] != "absent":
                    continue
                dynamic = config / dynamic_name
                if dynamic.is_symlink():
                    target = Path(os.readlink(dynamic))
                    resolved = target if target.is_absolute() else config / target
                    if not resolved.exists():
                        fallback = gtk_source_path(version, "blox-theme-empty-dark.css" if dark else "blox-theme-empty.css")
                        _replace_known_symlink(dynamic, fallback, (target, fallback))
        record = current_generation(root)
        active = bool(record and "gtk" in record[1]["enabled_targets"])
        ensure_gtk_loaders(root, active)
        return integration


def _remove_managed_loader(link: Path, expected: Path) -> None:
    if not link.is_symlink():
        if link.exists():
            raise RuntimeFailure(f"refusing to remove conflicting theme loader: {link}")
        return
    if Path(os.readlink(link)) != expected:
        raise RuntimeFailure(f"refusing to remove unexpected theme loader: {link}")
    link.unlink()


def sync_dynamic_loaders(root: Path, enabled_targets: Iterable[str], targets_to_sync: Iterable[str] | None = None) -> None:
    enabled = set(enabled_targets)
    selected = set(TARGET_FILES) if targets_to_sync is None else set(targets_to_sync)
    if "kitty" in selected:
        kitty = kitty_theme_link()
        kitty_expected = root / "current/kitty/theme.conf"
        if "kitty" in enabled:
            ensure_kitty_loader(root)
        else:
            _remove_managed_loader(kitty, kitty_expected)
    if "gtk" in selected:
        if "gtk" in enabled:
            ensure_gtk_loaders(root, True)
        else:
            generated_links = []
            for version in ("3", "4"):
                config = gtk_config_path(version)
                generated_links.extend((
                    (config / "settings.ini", root / f"current/gtk/gtk-{version}.0/settings.ini"),
                    (config / "blox-theme.css", root / f"current/gtk/gtk-{version}.0/gtk.css"),
                ))
            if any(link.is_symlink() and os.readlink(link) == str(expected) for link, expected in generated_links):
                ensure_gtk_loaders(root, False)
    if "cursor" in selected:
        ensure_cursor_loader(root, "cursor" in enabled)
    for target in phase7_loader_specs(root):
        if target in selected:
            ensure_phase7_loader(root, target, target in enabled)
    if "hyprland" in selected:
        _sync_hyprtoolkit_loader(root, "hyprland" in enabled)


def cleanup_managed_loaders(root: Path) -> None:
    pairs = ((kitty_theme_link(), root / "current/kitty/theme.conf"),)
    for link, expected in pairs:
        if link.is_symlink() and Path(os.readlink(link)) == expected:
            link.unlink()
    if _load_gtk_integration(root):
        try:
            ensure_gtk_loaders(root, False)
        except RuntimeFailure:
            pass
    try:
        ensure_cursor_loader(root, False)
    except RuntimeFailure:
        pass
    for target in phase7_loader_specs(root):
        try:
            remove_phase7_loader(root, target)
        except RuntimeFailure:
            pass
    _sync_hyprtoolkit_loader(root, False)


def verify_tracked_loaders(targets: Iterable[str]) -> None:
    selected = set(targets)
    checks = loader_checks()
    required = []
    if "quickshell" in selected:
        required.append("quickshell_loader")
    if "kitty" in selected:
        required.append("kitty_loader")
    failures = [name for name in required if not checks[name]["ok"]]
    if failures:
        details = "; ".join(f"{name}: {checks[name]['path']}" for name in failures)
        raise RuntimeFailure(f"tracked theme loader is missing ({details})")
    if "gtk" in selected:
        source_names = ("settings.ini", "gtk.css", "gtk-dark.css", "blox-theme-empty.css", "blox-theme-empty-dark.css")
        missing = [str(gtk_source_path(version, name)) for version in ("3", "4") for name in source_names if not gtk_source_path(version, name).is_file()]
        if missing:
            raise RuntimeFailure(f"tracked GTK loader is missing: {', '.join(missing)}")
        integration = _load_gtk_integration(state_dir())
        if integration is None:
            for version in ("3", "4"):
                for name in ("gtk.css", "gtk-dark.css"):
                    path = gtk_config_path(version) / name
                    if path.exists() or path.is_symlink():
                        raise RuntimeFailure("existing GTK stylesheet loaders require explicit migration; run: themectl setup gtk --yes")
        for version in ("3", "4"):
            config = gtk_config_path(version)
            allowed = {
                "settings.ini": (gtk_source_path(version, "settings.ini"), state_dir() / f"current/gtk/gtk-{version}.0/settings.ini"),
                "blox-theme.css": (gtk_source_path(version, "blox-theme-empty.css"), state_dir() / f"current/gtk/gtk-{version}.0/gtk.css"),
                "blox-theme-dark.css": (gtk_source_path(version, "blox-theme-empty-dark.css"), state_dir() / f"current/gtk/gtk-{version}.0/gtk.css"),
            }
            if integration:
                light_original = integration["loaders"][version]["gtk.css"]
                dark_original = integration["loaders"][version]["gtk-dark.css"]
                if light_original["kind"] == "symlink":
                    allowed["blox-theme.css"] += (Path(light_original["target"]),)
                if dark_original["kind"] == "symlink":
                    allowed["blox-theme-dark.css"] += (Path(dark_original["target"]),)
            for loader_name in ("gtk.css", "gtk-dark.css"):
                allowed_targets = [gtk_source_path(version, loader_name)]
                if integration and integration["loaders"][version][loader_name]["kind"] == "symlink":
                    allowed_targets.append(Path(integration["loaders"][version][loader_name]["target"]))
                allowed[loader_name] = tuple(allowed_targets)
            for name, targets_allowed in allowed.items():
                path = config / name
                if path.exists() and not path.is_symlink():
                    raise RuntimeFailure(f"refusing to replace conflicting GTK loader: {path}")
                if path.is_symlink() and os.readlink(path) not in {str(item) for item in targets_allowed} and not _same_file_content(_link_target_path(path, os.readlink(path)), gtk_source_path(version, name)):
                    raise RuntimeFailure(f"refusing to replace unexpected GTK loader: {path}")


def loader_checks(root: Path | None = None) -> dict[str, dict[str, Any]]:
    root = root or state_dir()
    kitty_link = kitty_theme_link()
    expected_kitty = root / "current/kitty/theme.conf"
    kitty = kitty_config_path()
    quickshell = quickshell_config_path() / "shared/Theme.qml"
    startup = quickshell_config_path().parents[1] / "hypr/conf.d/autostart.lua"
    try:
        kitty_text = kitty.read_text(encoding="utf-8")
    except OSError:
        kitty_text = ""
    try:
        quickshell_text = quickshell.read_text(encoding="utf-8")
    except OSError:
        quickshell_text = ""
    try:
        startup_text = startup.read_text(encoding="utf-8")
    except OSError:
        startup_text = ""
    checks = {
        "quickshell_loader": {"ok": "watchChanges: true" in quickshell_text and "function loadJson" in quickshell_text, "path": str(quickshell)},
        "kitty_loader": {"ok": kitty_include_line() in kitty_text, "path": str(kitty), "expected": kitty_include_line()},
        "kitty_generated_link": {"ok": kitty_link.is_symlink() and Path(os.readlink(kitty_link)) == expected_kitty, "path": str(kitty_link), "expected": str(expected_kitty)},
        "session_reconcile": {"ok": "scripts/theme/reconcile.sh" in startup_text, "path": str(startup)},
    }
    try:
        cursor_record = _load_cursor_integration(root)
        cursor_metadata = _cursor_metadata(root) if (root / "current/cursor/metadata.json").is_file() else None
        cursor_link = cursor_icon_link()
        generated = bool(cursor_metadata and cursor_metadata["mode"] == "generated")
        expected_cursor = root / f"cursors/{cursor_metadata['cache_key']}/theme" if generated else None
        checks["cursor_setup"] = {"ok": cursor_record is not None, "path": str(cursor_integration_path(root)), "required": False, "recovery": "themes/bin/themectl setup cursor --yes"}
        checks["cursor_generated_link"] = {
            "ok": not generated or (cursor_link.is_symlink() and os.readlink(cursor_link) == str(expected_cursor) and expected_cursor.is_dir()),
            "path": str(cursor_link), "expected": str(expected_cursor) if expected_cursor else None, "required": generated,
        }
    except RuntimeFailure as error:
        checks["cursor_setup"] = {"ok": False, "path": str(cursor_integration_path(root)), "error": str(error), "required": False}
    for version in ("3", "4"):
        light_loader = gtk_source_path(version, "gtk.css")
        dark_loader = gtk_source_path(version, "gtk-dark.css")
        live_light = gtk_config_path(version) / "gtk.css"
        live_dark = gtk_config_path(version) / "gtk-dark.css"
        checks[f"gtk{version}_loader"] = {"ok": light_loader.is_file() and dark_loader.is_file() and live_light.is_symlink() and Path(os.readlink(live_light)) == light_loader and live_dark.is_symlink() and Path(os.readlink(live_dark)) == dark_loader, "path": str(gtk_config_path(version)), "expected": f"gtk.css -> {light_loader}; gtk-dark.css -> {dark_loader}"}
        metadata_path = root / "current/gtk/metadata.json"
        if metadata_path.is_file():
            try:
                metadata = _gtk_metadata(root)
                expected_css = root / f"current/gtk/gtk-{version}.0/gtk.css" if metadata["generated_css"] else gtk_source_path(version, "blox-theme-empty.css")
            except RuntimeFailure:
                expected_css = root / f"current/gtk/gtk-{version}.0/gtk.css"
            settings = gtk_config_path(version) / "settings.ini"
            css = gtk_config_path(version) / "blox-theme.css"
            dark_css = gtk_config_path(version) / "blox-theme-dark.css"
            expected_settings = root / f"current/gtk/gtk-{version}.0/settings.ini"
            checks[f"gtk{version}_generated_links"] = {
                "ok": settings.is_symlink() and os.readlink(settings) == str(expected_settings) and css.is_symlink() and os.readlink(css) == str(expected_css) and dark_css.is_symlink() and os.readlink(dark_css) == str(expected_css),
                "path": str(gtk_config_path(version)),
                "expected": f"settings.ini -> {expected_settings}; generated CSS links -> {expected_css}",
            }
    return checks


def _reload_quickshell(mode: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]], restart: bool = False) -> str | None:
    if restart:
        command = _ipc_command("theme", "reloadCursor")
        result = run_command(command)
        if result.returncode != 0:
            return f"Quickshell restart failed; run: {_command_text(command)}"
        return None

    function = "reset" if mode == "reset" else "reload"
    command = _ipc_command("theme", function)
    result = run_command(command)
    if result.returncode != 0:
        return f"Quickshell reload failed; run: {_command_text(command)}"
    return None


def _quickshell_icon_theme_changed(previous_path: Path | None, theme: dict[str, Any]) -> bool:
    requested = theme.get("icons", {}).get("theme")
    if not requested:
        return False
    if previous_path is None:
        return True
    try:
        previous = json.loads((previous_path / "quickshell/theme.json").read_text(encoding="utf-8"))
        return previous.get("icons", {}).get("theme") != requested
    except (OSError, json.JSONDecodeError, TypeError):
        return True


def _reload_widgets(mode: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]]) -> str | None:
    function = "resetWidgets" if mode == "reset" else "reloadWidgets"
    command = _ipc_command("theme", function)
    result = run_command(command)
    if result.returncode != 0:
        return f"Widget profile reload failed; run: {_command_text(command)}"
    return None


def _reload_wallpaper(root: Path, mode: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]]) -> str | None:
    function = "resetWallpaper" if mode == "reset" else "reloadWallpaper"
    command = _ipc_command("theme", function)
    result = run_command(command)
    if result.returncode != 0:
        return f"Quickshell wallpaper reload failed; run: {_command_text(command)}"
    return None


def _kitty_sockets() -> list[Path]:
    return sorted(path for path in Path("/tmp").glob("kitty-tabs-recover-*") if path.is_socket())


def _reload_kitty(run_command: Callable[[list[str]], subprocess.CompletedProcess[str]]) -> list[str]:
    sockets = _kitty_sockets()
    if not sockets:
        return ["Kitty is not running; new windows will read the generated theme"]
    warnings = []
    for socket in sockets:
        command = ["kitty", "@", "--to", f"unix:{socket}", "load-config"]
        if run_command(command).returncode != 0:
            warnings.append(f"Kitty reload failed; run: {_command_text(command)}")
    return warnings


def _reload_gtk(root: Path, mode: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]]) -> list[str]:
    if mode == "reset":
        try:
            _, theme = load_theme(DEFAULT_THEME_ID)
            metadata = {"base_theme": theme["gtk"]["base_theme"], "font": f"{theme['fonts']['ui']} {theme['fonts']['gtk_size']}", "icon_theme": theme["icons"]["theme"], "variant": theme["variant"]}
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
            return [f"GTK reset metadata is invalid: {error}"]
    else:
        try:
            generated = _gtk_metadata(root)
            settings = (root / "current/gtk/gtk-4.0/settings.ini").read_text(encoding="utf-8")
            values = dict(line.split("=", 1) for line in settings.splitlines() if "=" in line)
            metadata = {"base_theme": generated["base_theme"], "font": values["gtk-font-name"], "icon_theme": values["gtk-icon-theme-name"], "variant": "dark" if values["gtk-application-prefer-dark-theme"] == "1" else "light"}
        except (OSError, KeyError, ValueError, RuntimeFailure) as error:
            return [f"GTK settings metadata is invalid: {error}"]
    commands = (
        ["gsettings", "set", "org.gnome.desktop.interface", "gtk-theme", metadata["base_theme"]],
        ["gsettings", "set", "org.gnome.desktop.interface", "font-name", metadata["font"]],
        ["gsettings", "set", "org.gnome.desktop.interface", "icon-theme", metadata["icon_theme"]],
        ["gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-dark" if metadata["variant"] == "dark" else "default"],
    )
    warnings = []
    for command in commands:
        if run_command(command).returncode != 0:
            warnings.append(f"GTK setting update failed; run: {_command_text(command)}")
    return warnings


def _reload_cursor(root: Path, mode: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]], defer_quickshell_restart: bool = False) -> list[str]:
    integration = _load_cursor_integration(root)
    if mode == "reset":
        if integration is None:
            return ["Cursor reset fallback is unavailable; run: themectl setup cursor --yes"]
        metadata = integration["fallback"]
    else:
        try:
            metadata = _cursor_metadata(root)
        except RuntimeFailure as error:
            return [str(error)]
    name = metadata["theme_name"]
    size = metadata["size"]
    commands = [
        ["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", name],
        ["gsettings", "set", "org.gnome.desktop.interface", "cursor-size", str(size)],
    ]
    if mode != "reset" and integration is not None:
        fallback = integration["fallback"]
        if (fallback["theme_name"], fallback["size"]) != (name, size):
            # Hyprland caches a cursor by theme name and size. Generated
            # variants keep the stable name `blox-generated`, so briefly
            # selecting the captured fallback makes it load the new files.
            commands.append(["hyprctl", "setcursor", fallback["theme_name"], str(fallback["size"])])
    commands.append(["hyprctl", "setcursor", name, str(size)])
    warnings = []
    for command in commands:
        if run_command(command).returncode != 0:
            warnings.append(f"Cursor setting update failed; run: {_command_text(command)}")
    if not defer_quickshell_restart or mode == "reset":
        reload_command = _ipc_command("theme", "reloadCursor")
        if run_command(reload_command).returncode != 0:
            warnings.append(
                "Blox shell cursor surfaces could not be reloaded; run: "
                f"{_command_text(reload_command)}"
            )
    return warnings


def _check_browser_targets(targets: Iterable[str]) -> None:
    for target in targets:
        if target not in BROWSER_TARGET_BY_ID:
            continue
        availability = detect_browser_target(target)
        if not availability["available"]:
            raise RuntimeFailure(f"{availability['label']} target is unavailable: {availability['reason']}")


def run_reload_actions(root: Path, targets: Iterable[str], mode: str = "reload", run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run, progress: Callable[[str, str, str], None] | None = None, defer_quickshell_restart: bool = False, quickshell_restart_pending: bool = False, legacy_editor_theme: dict[str, Any] | None = None) -> list[str]:
    warnings = []
    for target in targets:
        if progress is not None:
            progress(target, "active", "Applying…")
        warning_start = len(warnings)
        if target == "quickshell":
            warning = _reload_quickshell(
                mode,
                run_command,
                restart=quickshell_restart_pending and not defer_quickshell_restart and mode != "reset",
            )
            if warning:
                warnings.append(warning)
        elif target == "widgets":
            warning = _reload_widgets(mode, run_command)
            if warning:
                warnings.append(warning)
        elif target == "wallpaper":
            warning = _reload_wallpaper(root, mode, run_command)
            if warning:
                warnings.append(warning)
        elif target == "kitty":
            warnings.extend(_reload_kitty(run_command))
        elif target in BROWSER_TARGET_BY_ID:
            guidance = browser_target(target).restart_guidance
            warnings.append(guidance if mode != "reset" else f"{browser_target(target).label} will use its browser default after restart")
        elif target == "gtk":
            warnings.extend(_reload_gtk(root, mode, run_command))
        elif target == "cursor":
            warnings.extend(_reload_cursor(root, mode, run_command, defer_quickshell_restart=defer_quickshell_restart))
        elif target == "hyprland":
            command = ["hyprctl", "reload"]
            if run_command(command).returncode != 0:
                warnings.append(f"Hyprland reload failed; run: {_command_text(command)}")
            warnings.append(
                "Hyprtoolkit apps must be restarted to discard the generated theme"
                if mode == "reset"
                else "Hyprtoolkit apps must be restarted to read the generated theme"
            )
        elif target == "hyprlock":
            warnings.append("Hyprlock will read the canonical fallback the next time the lock screen starts" if mode == "reset" else "Hyprlock theme changes apply the next time the lock screen starts")
        elif target == "btop":
            warnings.append("btop must be restarted to read its canonical fallback" if mode == "reset" else "btop must be restarted to read its generated theme")
        elif target == "micro":
            warnings.append("Micro must be restarted to read its canonical fallback" if mode == "reset" else "Micro must be restarted to read its generated colourscheme")
        elif target == "glow":
            warnings.append("Glow will use the canonical fallback on its next invocation" if mode == "reset" else "Glow will use the generated style on its next invocation")
        elif target in ("code", "cursor_editor"):
            editor = "Code" if target == "code" else "Cursor"
            if mode == "reset":
                try:
                    warnings.extend(reset_editor_settings(root, target))
                    remove_editor_extension(target)
                    warnings.append(f"{editor} theme package and owned settings reset; existing windows may need Reload Window")
                except (OSError, EditorSettingsFailure, RuntimeFailure) as error:
                    warnings.append(f"{editor} settings or package were not reset: {error}")
            else:
                fragment_path = root / ("current/code/settings.json" if target == "code" else "current/cursor-editor/settings.json")
                try:
                    fragment = json.loads(fragment_path.read_text(encoding="utf-8"))
                    if legacy_editor_theme is not None and migrate_legacy_editor_customizations(editor_settings_path(target), legacy_editor_theme):
                        warnings.append(f"{editor} legacy colour customisations migrated to the packaged theme")
                    warnings.extend(install_editor_extension(root, target))
                    apply_editor_settings(root, target, fragment)
                    warnings.append(f"{editor} theme package and settings applied; use Reload Window for existing windows")
                except (OSError, json.JSONDecodeError, EditorSettingsFailure, RuntimeFailure) as error:
                    warnings.append(f"{editor} settings were not changed: {error}")
        elif target == "t3code":
            try:
                if mode == "reset":
                    warnings.extend(_reset_t3code_theme(root))
                else:
                    _publish_t3code_theme(root)
            except (OSError, RuntimeFailure) as error:
                warnings.append(f"T3Code theme was not changed: {error}")
        elif target == "zed":
            try:
                if mode == "reset":
                    warnings.extend(_reset_zed_theme(root))
                else:
                    _publish_zed_theme(root)
            except (OSError, EditorSettingsFailure, RuntimeFailure) as error:
                warnings.append(f"Zed theme was not changed: {error}")
        elif target == "stylus":
            warnings.append("Stylus's generated UserCSS was removed; manually remove any previously imported copy" if mode == "reset" else f"Open or reload {root / 'current/stylus/blox-system.user.css'} in a browser with Stylus, then choose Install style the first time or Reinstall style after an earlier import; remove older duplicate Blox Web Theme entries first; manifest.json lists included and excluded sites")
        elif target == "obsidian":
            try:
                if mode == "reset":
                    warnings.extend(reset_obsidian_theme(root, run_command, real_cli=run_command is _run))
                else:
                    vault = publish_obsidian_theme(root, run_command, real_cli=run_command is _run)
                    warnings.append(f"Obsidian native theme selected in {vault}")
            except (OSError, EditorSettingsFailure, ObsidianFailure) as error:
                warnings.append(f"Obsidian theme was not changed: {error}")
        elif target == "powerlevel10k":
            warnings.append("Powerlevel10k will use the base configuration in new shells" if mode == "reset" else "Powerlevel10k theme changes apply to new shells; source the generated fragment to update the current shell")
        if progress is not None:
            target_warnings = warnings[warning_start:]
            failed = next((warning for warning in target_warnings if any(token in warning.lower() for token in ("failed", "not changed", "unavailable", "could not"))), "")
            if failed:
                progress(target, "failed", failed)
            elif target == "stylus":
                progress(target, "manual", "Apply manually")
            elif target == "cursor" and defer_quickshell_restart and mode != "reset":
                progress(target, "restart", "Complete to reload Blox surfaces")
            elif target == "quickshell" and quickshell_restart_pending and defer_quickshell_restart and mode != "reset":
                progress(target, "restart", "Complete to reload Blox surfaces")
            elif target in ("gtk", "helium", "chromium", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "powerlevel10k"):
                progress(target, "restart", "Restart needed" if target not in ("code", "cursor_editor") else "Reload Window")
            else:
                progress(target, "applied", "Applied")
    return warnings


def apply_theme(theme_path: Path, theme: dict[str, Any], targets: Iterable[str], run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run, renderer: Callable[[dict[str, Any]], tuple[dict[str, str], list[str]]] = render_theme, cursor_builder: Callable[[dict[str, Any], Path], tuple[Path, bool]] | None = None, progress: Callable[[dict[str, Any]], None] | None = None, defer_quickshell_restart: bool = False, authoritative_targets: bool = False) -> tuple[dict[str, Any], list[str]]:
    root = state_dir()
    selected = tuple(dict.fromkeys(targets))
    enabled_selection = {
        target
        for target in selected
        if not authoritative_targets or theme.get("targets", {}).get(target, False)
    }
    enabled = tuple(target for target in selected if target in enabled_selection)
    progress_total = 3 + len(selected)

    def report(kind: str, stage: str, state: str, message: str, completed: int, target: str = "", **extra: Any) -> None:
        if progress is not None:
            event = {"kind": kind, "stage": stage, "target": target, "state": state, "message": message, "completed": completed, "total": progress_total}
            event.update(extra)
            progress(event)

    unknown = sorted(set(selected) - set(TARGET_NAMES))
    if unknown:
        raise RuntimeFailure(f"unsupported runtime target(s): {', '.join(unknown)}")
    if not selected:
        raise RuntimeFailure("at least one target is required")
    _check_browser_targets(enabled)
    if "obsidian" in enabled:
        try:
            obsidian_preflight(root)
        except ObsidianFailure as error:
            raise RuntimeFailure(str(error)) from error
    verify_tracked_loaders(enabled)
    with ApplicationLock(root):
        generations = root / "generations"
        generations.mkdir(parents=True, exist_ok=True)
        previous_record = current_generation(root)
        previous_path = previous_record[0] if previous_record else None
        previous_manifest = previous_record[1] if previous_record else None
        legacy_editor_theme = theme
        if previous_manifest is not None:
            try:
                _, legacy_editor_theme = load_theme(previous_manifest["source"])
            except (FileNotFoundError, OSError, json.JSONDecodeError, ValueError, KeyError, TypeError):
                pass
        render_input = theme
        if not Path(theme["wallpaper"]["path"]).expanduser().is_absolute():
            render_input = dict(theme)
            render_input["wallpaper"] = dict(theme["wallpaper"])
            render_input["wallpaper"]["path"] = str(resolve_wallpaper_path(theme["wallpaper"]["path"], theme_path))
        report("stage", "prepare", "active", "Generating target files", 0)
        files, _ = renderer(render_input)
        for target in enabled:
            missing = [name for name in TARGET_REQUIRED_FILES[target] if name not in files]
            if missing:
                report("stage", "prepare", "failed", f"Renderer did not produce {target}: {', '.join(missing)}", 0)
                raise RuntimeFailure(f"renderer did not produce {target}: {', '.join(missing)}")
        report("stage", "prepare", "done", f"Theme checked · {len(files)} generated files ready", 1)
        report("stage", "cursor", "active", "Checking generated cursor assets", 1)
        cursor_message = "No cursor assets enabled"
        if "cursor" in enabled:
            try:
                metadata = json.loads(files["cursor/metadata.json"])
                if metadata["mode"] == "generated":
                    from .cursor import CursorFailure, build_cursor_cache

                    try:
                        report("stage", "cursor", "active", "Building generated cursor assets", 1)
                        if cursor_builder is None:
                            def cursor_progress(detail: str) -> None:
                                report("stage", "cursor", "active", f"Building generated cursor assets • {detail}", 1)

                            _, cache_hit = build_cursor_cache(metadata, root, progress=cursor_progress)
                        else:
                            _, cache_hit = cursor_builder(metadata, root)
                        cursor_message = "Generated cursor cache ready" if cache_hit else "Generated cursor assets built"
                    except CursorFailure as error:
                        report("stage", "cursor", "failed", str(error), 1)
                        raise RuntimeFailure(str(error)) from error
                else:
                    cursor_message = "Installed cursor theme ready"
            except (json.JSONDecodeError, KeyError, TypeError) as error:
                report("stage", "cursor", "failed", f"Renderer produced invalid cursor metadata: {error}", 1)
                raise RuntimeFailure(f"renderer produced invalid cursor metadata: {error}") from error
            _ensure_cursor_integration(root, run_command)
        report("stage", "cursor", "done", cursor_message, 2)

        generation_id = _new_generation_id()
        candidate = generations / f".candidate-{uuid.uuid4().hex}"
        final = generations / generation_id
        candidate.mkdir(mode=0o700)
        application_started = False
        try:
            report("stage", "activation", "active", "Writing an atomic theme generation", 2)
            _copy_previous(previous_path, candidate)
            for target in selected:
                _remove_target(candidate, target)
            for target in enabled:
                for name in TARGET_FILES[target]:
                    if name in files:
                        _write_text(candidate / name, files[name])
            if authoritative_targets:
                previous_enabled = set(previous_manifest.get("enabled_targets", [])) if previous_manifest else set()
                changed_targets = tuple(
                    target
                    for target in selected
                    if (target in enabled_selection and (
                        target not in previous_enabled
                        or _target_signature(previous_path, target) != _target_signature(candidate, target)
                    )) or (target not in enabled_selection and target in previous_enabled)
                )
            else:
                changed_targets = tuple(target for target in selected if _target_changed(previous_path, previous_manifest, candidate, target))
            if "obsidian" in enabled_selection and "obsidian" in selected and obsidian_needs_reapply(root) and "obsidian" not in changed_targets:
                changed_targets = (*changed_targets, "obsidian")
            unchanged_targets = tuple(target for target in selected if target not in changed_targets)
            icon_theme_changed = "quickshell" in changed_targets and _quickshell_icon_theme_changed(previous_path, theme)
            changed_enabled_targets = tuple(target for target in changed_targets if target in enabled_selection)
            removed_targets = tuple(target for target in changed_targets if target not in enabled_selection)
            pending_reloads = ("quickshell",) if defer_quickshell_restart and ("cursor" in changed_enabled_targets or icon_theme_changed) else ()
            sources = _target_sources(previous_manifest, selected, theme_path, theme)
            active_targets = sorted(target for target, names in TARGET_FILES.items() if any((candidate / name).is_file() for name in names))
            sources = {target: sources[target] for target in active_targets}
            manifest = {
                "schema_version": 1,
                "renderer_version": RENDERER_VERSION,
                "generation_id": generation_id,
                "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "operation": "apply",
                "source": str(theme_path.resolve()),
                "source_sha256": sha256_text(canonical_json(theme)),
                "theme_id": theme["id"],
                "origin": _origin_metadata(theme_path, theme),
                "enabled_targets": active_targets,
                "target_sources": sources,
                "files": _manifest_files(candidate),
                "derived": {"ansi": json.loads(files["quickshell/theme.json"])["ansi"] if "quickshell/theme.json" in files else {}},
            }
            _write_text(candidate / "manifest.json", canonical_json(manifest))
            _fsync_directory(candidate)
            os.replace(candidate, final)
            _fsync_directory(generations)
            validate_generation(final)
            _switch_generation(root, final)
            try:
                sync_dynamic_loaders(root, active_targets, selected)
            except (OSError, RuntimeFailure):
                try:
                    if previous_path:
                        _switch_generation(root, previous_path)
                        try:
                            sync_dynamic_loaders(root, previous_manifest["enabled_targets"] if previous_manifest else (), selected)
                        except (OSError, RuntimeFailure):
                            pass
                    else:
                        cleanup_managed_loaders(root)
                        (root / "current").unlink(missing_ok=True)
                        (root / "active.json").unlink(missing_ok=True)
                finally:
                    shutil.rmtree(final, ignore_errors=True)
                raise
            report("stage", "activation", "done", "Theme generation activated", 3)
            report(
                "stage",
                "applications",
                "active",
                f"Applying {len(changed_targets)} changed targets · {len(unchanged_targets)} unchanged",
                3,
                changed_targets=list(changed_targets),
                unchanged_targets=list(unchanged_targets),
                pending_reloads=list(pending_reloads),
            )
            application_started = True
            completed_targets = 0

            def report_target(target: str, state: str, message: str) -> None:
                nonlocal completed_targets
                if state != "active":
                    completed_targets += 1
                report("target", "applications", state, message, 3 + completed_targets, target)

            for target in unchanged_targets:
                report_target(target, "unchanged", "Unchanged")
            reload_warnings = run_reload_actions(
                root,
                removed_targets,
                mode="reset",
                run_command=run_command,
                progress=report_target,
                defer_quickshell_restart=defer_quickshell_restart,
                legacy_editor_theme=legacy_editor_theme,
            )
            reload_warnings.extend(run_reload_actions(
                root,
                changed_enabled_targets,
                run_command=run_command,
                progress=report_target,
                defer_quickshell_restart=defer_quickshell_restart,
                quickshell_restart_pending="cursor" in changed_enabled_targets or icon_theme_changed,
                legacy_editor_theme=legacy_editor_theme,
            ))
            obsidian_failure = _obsidian_failure_warning(reload_warnings)
            if obsidian_failure is not None:
                _restore_generation_after_application_failure(root, previous_path, previous_manifest, selected, final)
                raise RuntimeFailure(obsidian_failure)
            report("stage", "applications", "done", "Application targets finished", progress_total)
            _prune_generations(root, final)
            return manifest, reload_warnings
        except Exception as error:
            report("stage", "applications" if application_started else "activation", "failed", str(error), 3 if application_started else 2)
            shutil.rmtree(candidate, ignore_errors=True)
            raise


def reconcile(targets: Iterable[str] | None = None, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run) -> tuple[dict[str, Any], list[str]]:
    root = state_dir()
    with ApplicationLock(root):
        record = current_generation(root)
        if not record:
            raise RuntimeFailure("no active theme generation")
        _, manifest = record
        selected = tuple(targets) if targets is not None else tuple(manifest["enabled_targets"])
        unknown = sorted(set(selected) - set(manifest["enabled_targets"]))
        if unknown:
            raise RuntimeFailure(f"target(s) are not active: {', '.join(unknown)}")
        sync_dynamic_loaders(root, manifest["enabled_targets"], selected)
        try:
            _, legacy_editor_theme = load_theme(manifest["source"])
        except (FileNotFoundError, OSError, json.JSONDecodeError, ValueError, KeyError, TypeError):
            legacy_editor_theme = None
        warnings = run_reload_actions(root, selected, run_command=run_command, legacy_editor_theme=legacy_editor_theme)
        return manifest, warnings


def rollback(generation_id: str | None = None, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run) -> tuple[dict[str, Any], list[str]]:
    root = state_dir()
    with ApplicationLock(root):
        current_record = current_generation(root)
        if not current_record:
            raise RuntimeFailure("no active theme generation")
        current_path = current_record[0]
        if generation_id:
            if not GENERATION_PATTERN.fullmatch(generation_id):
                raise RuntimeFailure(f"invalid generation ID: {generation_id}")
            target = root / "generations" / generation_id
        else:
            candidates = sorted((path for path in (root / "generations").iterdir() if path.is_dir() and GENERATION_PATTERN.fullmatch(path.name) and path != current_path), key=lambda item: item.stat().st_mtime_ns, reverse=True)
            if not candidates:
                raise RuntimeFailure("no previous generation is available")
            target = candidates[0]
        if target == current_path:
            raise RuntimeFailure("requested generation is already active")
        manifest = validate_generation(target)
        _check_browser_targets(manifest["enabled_targets"])
        _switch_generation(root, target)
        try:
            sync_dynamic_loaders(root, manifest["enabled_targets"])
        except (OSError, RuntimeFailure):
            _switch_generation(root, current_path)
            try:
                sync_dynamic_loaders(root, current_record[1]["enabled_targets"])
            except (OSError, RuntimeFailure):
                pass
            raise
        current_targets = set(current_record[1]["enabled_targets"])
        restored_targets = set(manifest["enabled_targets"])
        removed_targets = sorted(current_targets - restored_targets)
        warnings = run_reload_actions(root, removed_targets, mode="reset", run_command=run_command)
        try:
            _, legacy_editor_theme = load_theme(current_record[1]["source"])
        except (FileNotFoundError, OSError, json.JSONDecodeError, ValueError, KeyError, TypeError):
            legacy_editor_theme = None
        warnings.extend(run_reload_actions(root, manifest["enabled_targets"], run_command=run_command, legacy_editor_theme=legacy_editor_theme))
        obsidian_failure = _obsidian_failure_warning(warnings)
        if obsidian_failure is not None:
            _restore_generation_after_application_failure(
                root,
                current_path,
                current_record[1],
                TARGET_NAMES,
            )
            raise RuntimeFailure(obsidian_failure)
        return manifest, warnings


def reset_target(target: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run) -> tuple[dict[str, Any], list[str]]:
    if target not in TARGET_NAMES:
        raise RuntimeFailure(f"unsupported runtime target: {target}")
    root = state_dir()
    with ApplicationLock(root):
        record = current_generation(root)
        if not record:
            raise RuntimeFailure("no active theme generation")
        previous, previous_manifest = record
        if target not in previous_manifest["enabled_targets"]:
            raise RuntimeFailure(f"target is not active: {target}")
        generations = root / "generations"
        generation_id = _new_generation_id()
        candidate = generations / f".candidate-{uuid.uuid4().hex}"
        final = generations / generation_id
        candidate.mkdir(mode=0o700)
        try:
            _copy_previous(previous, candidate)
            _remove_target(candidate, target)
            enabled = sorted(item for item in previous_manifest["enabled_targets"] if item != target)
            sources = {item: value for item, value in previous_manifest["target_sources"].items() if item != target}
            manifest = {
                "schema_version": 1,
                "renderer_version": RENDERER_VERSION,
                "generation_id": generation_id,
                "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "operation": f"reset-target:{target}",
                "source": previous_manifest["source"],
                "source_sha256": previous_manifest["source_sha256"],
                "theme_id": previous_manifest["theme_id"],
                "enabled_targets": enabled,
                "target_sources": sources,
                "files": _manifest_files(candidate),
                "derived": previous_manifest["derived"],
            }
            if previous_manifest.get("origin") is not None:
                manifest["origin"] = previous_manifest["origin"]
            _write_text(candidate / "manifest.json", canonical_json(manifest))
            _fsync_directory(candidate)
            os.replace(candidate, final)
            validate_generation(final)
            _switch_generation(root, final)
            try:
                sync_dynamic_loaders(root, enabled, (target,))
            except (OSError, RuntimeFailure):
                try:
                    _switch_generation(root, previous)
                    try:
                        sync_dynamic_loaders(root, previous_manifest["enabled_targets"], (target,))
                    except (OSError, RuntimeFailure):
                        pass
                finally:
                    shutil.rmtree(final, ignore_errors=True)
                raise
            warnings = run_reload_actions(root, (target,), mode="reset", run_command=run_command)
            obsidian_failure = _obsidian_failure_warning(warnings)
            if target == "obsidian" and obsidian_failure is not None:
                _restore_generation_after_application_failure(root, previous, previous_manifest, (target,), final)
                raise RuntimeFailure(obsidian_failure)
            _prune_generations(root, final)
            return manifest, warnings
        except Exception:
            shutil.rmtree(candidate, ignore_errors=True)
            raise
