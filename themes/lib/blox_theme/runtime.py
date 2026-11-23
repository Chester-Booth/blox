from __future__ import annotations

import copy
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
from .obsidian import ObsidianFailure, ObsidianSelectionConflict, needs_reapply as obsidian_needs_reapply, preflight as obsidian_preflight, publish as publish_obsidian_theme, reset as reset_obsidian_theme


from .runtime_common import (
    EDITOR_EXTENSION_DIR,
    EDITOR_LEGACY_EXTENSION_DIR,
    EDITOR_MODERN_UI_SUPPORT,
    EDITOR_SETTING_KEYS,
    GENERATION_PATTERN,
    HISTORY_LIMIT,
    LEGACY_TARGET_FILES,
    ObsidianPublicationConflict,
    PHASE7_FALLBACK_TARGETS,
    RUNTIME_ARTIFACTS,
    RuntimeFailure,
    T3CODE_THEME_ID,
    TARGET_FILES,
    TARGET_NAMES,
    TARGET_REQUIRED_FILES,
    ZED_THEME_WATCH_SETTLE_SECONDS,
    LockContended,
    _ObsidianConflictWarning,
    _atomic_write_text,
    _file_sha256,
    _fsync_directory,
    _run,
    _write_text,
)
from .runtime_editors import (
    _load_editor_integration,
    _publish_t3code_theme,
    _publish_zed_theme,
    _reset_t3code_theme,
    _reset_zed_theme,
    _save_editor_integration,
    apply_editor_settings,
    editor_extensions_path,
    editor_modern_ui_supported,
    editor_settings_integration_path,
    editor_settings_path,
    install_editor_extension,
    migrate_legacy_editor_customizations,
    publish_editor_target,
    remove_editor_extension,
    reset_editor_settings,
    t3code_base_dir,
    t3code_integration_path,
    t3code_paths,
    zed_config_dir,
    zed_integration_path,
    zed_paths,
)
from .runtime_loaders import (
    _cursor_metadata,
    _ensure_cursor_integration,
    _ensure_gtk_integration,
    _gtk_metadata,
    _ipc_command,
    _ipc_script,
    _load_cursor_integration,
    _load_gtk_integration,
    _managed_cursor_target,
    _pid_shell_path,
    _proc_main_pid,
    _save_gtk_integration,
    cleanup_managed_loaders,
    cursor_icon_link,
    cursor_integration_path,
    ensure_cursor_loader,
    ensure_gtk_loaders,
    ensure_kitty_loader,
    ensure_phase7_loader,
    gtk_config_path,
    gtk_integration_path,
    gtk_source_path,
    hyprtoolkit_theme_link,
    kitty_config_path,
    kitty_include_line,
    kitty_theme_link,
    loader_checks,
    phase7_loader_specs,
    quickshell_config_path,
    remove_phase7_loader,
    setup_cursor,
    setup_gtk,
    sync_dynamic_loaders,
    verify_tracked_loaders,
)


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


def _raise_obsidian_failure(warning: str) -> None:
    if isinstance(warning, _ObsidianConflictWarning):
        raise ObsidianPublicationConflict(warning)
    raise RuntimeFailure(warning)


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
            except ObsidianSelectionConflict as error:
                warnings.append(_ObsidianConflictWarning(f"Obsidian theme was not changed: {error}"))
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


class WidgetPublicationConflict(RuntimeFailure):
    """A competing generation superseded the requested widget publication."""


def apply_theme(theme_path: Path, theme: dict[str, Any], targets: Iterable[str], run_command: Callable[[list[str]], subprocess.CompletedProcess[str]] = _run, renderer: Callable[[dict[str, Any]], tuple[dict[str, str], list[str]]] = render_theme, cursor_builder: Callable[[dict[str, Any], Path], tuple[Path, bool]] | None = None, progress: Callable[[dict[str, Any]], None] | None = None, defer_quickshell_restart: bool = False, authoritative_targets: bool = False, preserve_history: bool = False, activate_only: bool = False, widget_generation: str | None = None, widget_publication: str | None = None) -> tuple[dict[str, Any], list[str]]:
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
        if widget_generation is not None:
            if selected != ("widgets",) or previous_path is None or previous_path.name != widget_generation:
                raise WidgetPublicationConflict("widget generation changed before publication")
        if widget_publication is not None:
            if (widget_generation is None or not isinstance(widget_publication, str)
                    or not GENERATION_PATTERN.fullmatch(widget_publication)
                    or (generations / widget_publication).exists()):
                raise WidgetPublicationConflict("invalid or occupied widget publication identity")
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

        generation_id = widget_publication or _new_generation_id()
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
            if widget_generation is not None:
                for key in ("source", "source_sha256", "theme_id", "origin", "derived"):
                    if key in previous_manifest:
                        manifest[key] = copy.deepcopy(previous_manifest[key])
                    else:
                        manifest.pop(key, None)
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
            if activate_only:
                return manifest, []
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
                _raise_obsidian_failure(obsidian_failure)
            report("stage", "applications", "done", "Application targets finished", progress_total)
            if not preserve_history:
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
            _raise_obsidian_failure(obsidian_failure)
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
                _raise_obsidian_failure(obsidian_failure)
            _prune_generations(root, final)
            return manifest, warnings
        except Exception:
            shutil.rmtree(candidate, ignore_errors=True)
            raise
