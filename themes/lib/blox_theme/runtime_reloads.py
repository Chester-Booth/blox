"""Target reload actions executed after activating a generated theme generation."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
from typing import Any, Callable, Iterable

from .browser_targets import BROWSER_TARGET_BY_ID, browser_target, detect_browser_target
from .core import DEFAULT_THEME_ID, load_theme
from .editor import EditorSettingsFailure
from .obsidian import (
    ObsidianFailure,
    ObsidianSelectionConflict,
    publish as publish_obsidian_theme,
    reset as reset_obsidian_theme,
)
from .runtime_common import RuntimeFailure, _ObsidianConflictWarning
from .runtime_editors import (
    _publish_t3code_theme,
    _publish_zed_theme,
    _reset_t3code_theme,
    _reset_zed_theme,
    apply_editor_settings,
    editor_settings_path,
    install_editor_extension,
    migrate_legacy_editor_customizations,
    remove_editor_extension,
    reset_editor_settings,
)
from .runtime_loaders import (
    _cursor_metadata,
    _gtk_metadata,
    _ipc_command,
    _load_cursor_integration,
)


def command_text(command: list[str]) -> str:
    return " ".join(command)


def reload_quickshell(
    mode: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    restart: bool = False,
) -> str | None:
    if restart:
        command = _ipc_command("theme", "reloadCursor")
        result = run_command(command)
        if result.returncode != 0:
            return f"Quickshell restart failed; run: {command_text(command)}"
        return None
    function = "reset" if mode == "reset" else "reload"
    command = _ipc_command("theme", function)
    result = run_command(command)
    if result.returncode != 0:
        return f"Quickshell reload failed; run: {command_text(command)}"
    return None


def quickshell_icon_theme_changed(previous_path: Path | None, theme: dict[str, Any]) -> bool:
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


def reload_widgets(
    mode: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
) -> str | None:
    function = "resetWidgets" if mode == "reset" else "reloadWidgets"
    command = _ipc_command("theme", function)
    result = run_command(command)
    if result.returncode != 0:
        return f"Widget profile reload failed; run: {command_text(command)}"
    return None


def reload_wallpaper(
    root: Path,
    mode: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
) -> str | None:
    del root
    function = "resetWallpaper" if mode == "reset" else "reloadWallpaper"
    command = _ipc_command("theme", function)
    result = run_command(command)
    if result.returncode != 0:
        return f"Quickshell wallpaper reload failed; run: {command_text(command)}"
    return None


def reload_kitty(
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    sockets: list[Path],
) -> list[str]:
    if not sockets:
        return ["Kitty is not running; new windows will read the generated theme"]
    warnings = []
    for socket in sockets:
        command = ["kitty", "@", "--to", f"unix:{socket}", "load-config"]
        if run_command(command).returncode != 0:
            warnings.append(f"Kitty reload failed; run: {command_text(command)}")
    return warnings


def reload_gtk(
    root: Path,
    mode: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
) -> list[str]:
    if mode == "reset":
        try:
            _, theme = load_theme(DEFAULT_THEME_ID)
            metadata = {
                "base_theme": theme["gtk"]["base_theme"],
                "font": f"{theme['fonts']['ui']} {theme['fonts']['gtk_size']}",
                "icon_theme": theme["icons"]["theme"],
                "variant": theme["variant"],
            }
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
            return [f"GTK reset metadata is invalid: {error}"]
    else:
        try:
            generated = _gtk_metadata(root)
            settings = (root / "current/gtk/gtk-4.0/settings.ini").read_text(encoding="utf-8")
            values = dict(line.split("=", 1) for line in settings.splitlines() if "=" in line)
            metadata = {
                "base_theme": generated["base_theme"],
                "font": values["gtk-font-name"],
                "icon_theme": values["gtk-icon-theme-name"],
                "variant": "dark" if values["gtk-application-prefer-dark-theme"] == "1" else "light",
            }
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
            warnings.append(f"GTK setting update failed; run: {command_text(command)}")
    return warnings


def reload_cursor(
    root: Path,
    mode: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    defer_quickshell_restart: bool = False,
) -> list[str]:
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
            commands.append(["hyprctl", "setcursor", fallback["theme_name"], str(fallback["size"])])
    commands.append(["hyprctl", "setcursor", name, str(size)])
    warnings = []
    for command in commands:
        if run_command(command).returncode != 0:
            warnings.append(f"Cursor setting update failed; run: {command_text(command)}")
    if not defer_quickshell_restart or mode == "reset":
        reload_command = _ipc_command("theme", "reloadCursor")
        if run_command(reload_command).returncode != 0:
            warnings.append(
                "Blox shell cursor surfaces could not be reloaded; run: "
                f"{command_text(reload_command)}"
            )
    return warnings


def check_browser_targets(
    targets: Iterable[str],
    detect_fn: Callable[[str], dict[str, Any]] = detect_browser_target,
) -> None:
    for target in targets:
        if target not in BROWSER_TARGET_BY_ID:
            continue
        availability = detect_fn(target)
        if not availability["available"]:
            raise RuntimeFailure(f"{availability['label']} target is unavailable: {availability['reason']}")


def execute_reload_actions(
    root: Path,
    targets: Iterable[str],
    *,
    mode: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    default_runner: Callable[[list[str]], subprocess.CompletedProcess[str]],
    kitty_sockets_fn: Callable[[], list[Path]],
    progress: Callable[[str, str, str], None] | None = None,
    defer_quickshell_restart: bool = False,
    quickshell_restart_pending: bool = False,
    legacy_editor_theme: dict[str, Any] | None = None,
) -> list[str]:
    warnings: list[str] = []
    for target in targets:
        if progress is not None:
            progress(target, "active", "Applying…")
        warning_start = len(warnings)
        if target == "quickshell":
            warning = reload_quickshell(
                mode,
                run_command,
                restart=quickshell_restart_pending and not defer_quickshell_restart and mode != "reset",
            )
            if warning:
                warnings.append(warning)
        elif target == "widgets":
            warning = reload_widgets(mode, run_command)
            if warning:
                warnings.append(warning)
        elif target == "wallpaper":
            warning = reload_wallpaper(root, mode, run_command)
            if warning:
                warnings.append(warning)
        elif target == "kitty":
            warnings.extend(reload_kitty(run_command, kitty_sockets_fn()))
        elif target in BROWSER_TARGET_BY_ID:
            guidance = browser_target(target).restart_guidance
            warnings.append(guidance if mode != "reset" else f"{browser_target(target).label} will use its browser default after restart")
        elif target == "gtk":
            warnings.extend(reload_gtk(root, mode, run_command))
        elif target == "cursor":
            warnings.extend(reload_cursor(root, mode, run_command, defer_quickshell_restart=defer_quickshell_restart))
        elif target == "hyprland":
            command = ["hyprctl", "reload"]
            if run_command(command).returncode != 0:
                warnings.append(f"Hyprland reload failed; run: {command_text(command)}")
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
                    warnings.extend(reset_obsidian_theme(root, run_command, real_cli=run_command is default_runner))
                else:
                    vault = publish_obsidian_theme(root, run_command, real_cli=run_command is default_runner)
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
