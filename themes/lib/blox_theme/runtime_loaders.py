"""Desktop target symlink loaders and health checks (Kitty, GTK, Cursor, Hyprland, Phase 7)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable

from .core import DEFAULT_THEME_ID, canonical_json, load_theme, render_theme, repository_root, state_dir
from .runtime_common import (
    PHASE7_FALLBACK_TARGETS,
    TARGET_FILES,
    TARGET_NAMES,
    RuntimeFailure,
    _atomic_write_text,
    _file_sha256,
    _fsync_directory,
    _run,
    _write_text,
)
from .runtime_editors import (
    editor_extensions_path,
    editor_settings_path,
    t3code_integration_path,
    t3code_paths,
    zed_integration_path,
    zed_paths,
)


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
    reader = read_cmdline or (lambda p: Path(f"/proc/{p}/cmdline").read_bytes().decode().split("\0"))
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
    service's own --path argument, otherwise the installed tree."""
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
    installed = Path(os.environ.get("BLOX_PREFIX", prefix_default)).expanduser() / "share/blox/shell"
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
    from .runtime import ApplicationLock

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
    from .runtime import ApplicationLock, current_generation

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


def cleanup_managed_loaders(root: Path, targets_to_clean: Iterable[str] | None = None) -> None:
    selected = set(TARGET_NAMES) if targets_to_clean is None else set(targets_to_clean)
    pairs = ((kitty_theme_link(), root / "current/kitty/theme.conf"),)
    for link, expected in pairs:
        if "kitty" in selected and link.is_symlink() and Path(os.readlink(link)) == expected:
            link.unlink()
    if "gtk" in selected and _load_gtk_integration(root):
        try:
            ensure_gtk_loaders(root, False)
        except RuntimeFailure:
            pass
    try:
        if "cursor" in selected:
            ensure_cursor_loader(root, False)
    except RuntimeFailure:
        pass
    for target in phase7_loader_specs(root):
        if target not in selected:
            continue
        try:
            remove_phase7_loader(root, target)
        except RuntimeFailure:
            pass
    if "hyprland" in selected:
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


