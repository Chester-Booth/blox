"""Editor target publication and reset (VS Code, Cursor, T3 Code, Zed)."""
from __future__ import annotations

import json
import os
import re
import shutil
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .core import (
    EDITOR_THEME_PACKAGE_NAME,
    EDITOR_THEME_PUBLISHER,
    EDITOR_THEME_RELATIVE_PATH,
    EDITOR_THEME_VERSION,
    ZED_THEME_FAMILY_NAME,
    canonical_json,
    editor_colours,
    sha256_text,
)
from .editor import (
    EditorSettingsFailure,
    apply_fragment,
    members,
    read_settings_values,
    restore_settings,
)
from .runtime_common import (
    EDITOR_EXTENSION_DIR,
    EDITOR_LEGACY_EXTENSION_DIR,
    EDITOR_MODERN_UI_SUPPORT,
    EDITOR_SETTING_KEYS,
    T3CODE_THEME_ID,
    ZED_THEME_WATCH_SETTLE_SECONDS,
    RuntimeFailure,
    _atomic_write_text,
    _file_sha256,
    _fsync_directory,
    _write_text,
)


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


def _capture_editor_settings(root: Path, target: str, fragment: dict[str, Any], settings_destination: Path | None = None, directory_fd: int | None = None) -> tuple[Path, dict[str, Any], dict[str, Any]]:
    settings = editor_settings_path(target)
    keys = {key: fragment[key] for key in EDITOR_SETTING_KEYS[target] if key in fragment}
    if not keys:
        raise RuntimeFailure(f"renderer produced no managed settings for {target}")
    data = _load_editor_integration(root)
    record = data["editors"].setdefault(target, {"settings_path": str(settings), "keys": {}, "last": {}})
    current = read_settings_values(settings_destination or settings, tuple(keys), follow_symlinks=settings_destination is None, directory_fd=directory_fd)
    for key, value in current.items():
        record["keys"].setdefault(key, value)
    record["settings_path"] = str(settings)
    _save_editor_integration(root, data)
    return settings_destination or settings, data, keys


def _record_editor_settings_applied(root: Path, target: str, data: dict[str, Any], values: dict[str, Any]) -> None:
    data["editors"][target]["last"] = values
    _save_editor_integration(root, data)


def apply_editor_settings(root: Path, target: str, fragment: dict[str, Any], *, settings_destination: Path | None = None, directory_fd: int | None = None) -> None:
    settings, data, values = _capture_editor_settings(root, target, fragment, settings_destination, directory_fd)
    apply_fragment(settings, values, follow_symlinks=settings_destination is None, directory_fd=directory_fd)
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


def install_editor_extension(root: Path, target: str, *, retire_legacy: bool = True) -> list[str]:
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
    return _remove_legacy_editor_extension(extension_root) if retire_legacy else []


def publish_editor_target(root: Path, target: str, *, external_image: dict[str, Any]) -> None:
    """Publish application packages and selections without restarting applications."""
    if target in ("code", "cursor_editor"):
        from .target_preimage import editor_publication_destination
        from .apply_coordinator import BeforeTargetPublicationFailure, ApplyError
        try:
            destination, directory_fd = editor_publication_destination(target, external_image)
        except (ApplyError, OSError) as error:
            raise BeforeTargetPublicationFailure(str(error)) from error
        try:
            fragment = json.loads((_editor_package_source(root, target) / "settings.json").read_text(encoding="utf-8"))
            install_editor_extension(root, target, retire_legacy=False)
            apply_editor_settings(root, target, fragment, settings_destination=destination, directory_fd=directory_fd)
            # The pinned file may be correct while the application's link changed.
            from .target_preimage import verify_editor_link
            verify_editor_link(target, external_image)
        finally:
            os.close(directory_fd)
    elif target == "zed":
        _publish_zed_theme(root)
    elif target == "t3code":
        _publish_t3code_theme(root)
    else:
        raise RuntimeFailure(f"unsupported editor publication target: {target}")


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


