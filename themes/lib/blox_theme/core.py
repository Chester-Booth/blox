from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import RENDERER_VERSION


EXIT_OK = 0
EXIT_USAGE = 2
EXIT_VALIDATION = 3
EXIT_DEPENDENCY = 4
EXIT_RENDER = 5
EXIT_APPLY = 6
EXIT_RELOAD_WARNING = 7
EXIT_LOCKED = 8

THEME_TARGET_KEYS = (
    "quickshell", "widgets", "gtk", "helium", "chromium", "cursor", "wallpaper", "kitty",
    "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "t3code", "zed",
    "stylus", "obsidian", "powerlevel10k", "sddm", "grub",
)
IMPLEMENTED_TARGETS = ("quickshell", "widgets", "kitty", "wallpaper", "gtk", "helium", "chromium", "cursor", "hyprland", "hyprlock", "btop", "micro", "glow", "code", "cursor_editor", "t3code", "zed", "stylus", "obsidian", "powerlevel10k")
DEFERRED_TARGETS = {}
TARGET_LIMITATIONS = {
    "hyprland": "Hyprtoolkit apps must be restarted after Apply",
    "hyprlock": "Hyprlock changes apply when the next lock process starts",
    "btop": "btop must be restarted after Apply",
    "micro": "Micro must be restarted after Apply",
    "code": "Code theme package and settings apply automatically; Modern UI follows roundness; use Reload Window for existing windows",
    "cursor_editor": "Cursor theme package and font family apply automatically; Modern UI is not managed by this version; use Reload Window for existing windows",
    "t3code": "Needs T3Code 0.0.37 nightly or newer with environment themes; this can update other T3Code clients connected to this machine",
    "zed": "Zed watches the generated theme and settings; existing Zed windows update automatically",
    "stylus": "Open or reload the generated .user.css in a browser with Stylus, then choose Install style the first time or Reinstall style after an earlier import; remove older duplicate Blox Web Theme entries first; manifest.json lists included and excluded sites",
    "obsidian": "Obsidian uses a generated native theme package and selects it in the one explicitly chosen vault; open Obsidian updates live and a closed vault reads the selection on its next launch",
    "powerlevel10k": "Powerlevel10k changes apply to new shells",
    "helium": "Helium must be restarted after Apply",
    "chromium": "Chromium must be restarted after Apply",
}

HYPRLAND_RADIUS_BASE = 12
GTK_RADIUS_BASE = 12
AUTOMATIC_GAP_BASE = 20
MINIMUM_DENSITY_SCALE = 0.75
ZED_THEME_SCHEMA = "https://zed.dev/schema/themes/v0.2.0.json"
ZED_THEME_FAMILY_NAME = "Blox generated"
ZED_THEME_AUTHOR = "Blox"
# Obsidian matches a native theme by its manifest name and its directory
# basename. Keep both human-readable so the generated theme is recognised.
OBSIDIAN_THEME_DIRECTORY = "Blox generated"
OBSIDIAN_THEME_NAME = "Blox generated"
OBSIDIAN_THEME_VERSION = "1.0.0"
OBSIDIAN_THEME_MIN_APP_VERSION = "1.13.0"
OBSIDIAN_THEME_AUTHOR = "Blox"

def resolved_bar_items(bar: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Return a complete, ordered bar registry with optional theme overrides."""
    source = (bar or {}).get("items", [])
    overrides = {item["id"]: item for item in source}
    # Prior to the movable drawer toggle, ``tray`` denoted the freedesktop
    # application tray. A complete old registry never contains the new id, so
    # migrate that override while giving the new toggle its normal placement.
    if "tray" in overrides and "application-tray" not in overrides:
        overrides["application-tray"] = {**overrides.pop("tray"), "id": "application-tray"}
    items = [{**default, **overrides.get(default["id"], {})} for default in default_bar_items()]
    tray = next(item for item in items if item["id"] == "tray")
    if tray["region"] == "hidden":
        tray["region"] = "end"
    visible = sorted(
        (item for item in items if item["region"] == tray["region"]),
        key=lambda item: item["order"],
    )
    tray_index = visible.index(tray)
    visible.remove(tray)
    if tray["region"] == "start":
        visible.append(tray)
    elif tray["region"] == "end" or tray_index < (len(visible) + 1) / 2:
        visible.insert(0, tray)
    else:
        visible.append(tray)
    for order, item in enumerate(visible):
        item["order"] = order

    application_tray = next(item for item in items if item["id"] == "application-tray")
    application_tray["region"] = "hidden"
    hidden = sorted(
        (item for item in items if item["region"] == "hidden" and item["id"] != "application-tray"),
        key=lambda item: item["order"],
    )
    if tray["region"] == "start":
        tray_opens_forward = True
    elif tray["region"] == "centre":
        centre = sorted(
            (item for item in items if item["region"] == "centre"),
            key=lambda item: item["order"],
        )
        tray_opens_forward = bool(centre) and centre[-1]["id"] == "tray"
    else:
        tray_opens_forward = False
    hidden.insert(len(hidden) if tray_opens_forward else 0, application_tray)
    for order, item in enumerate(hidden):
        item["order"] = order
    return items


@dataclass
class CheckResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def repository_root() -> Path:
    return Path(__file__).resolve().parents[3]


def themes_dir() -> Path:
    configured = os.environ.get("BLOX_DATA_DIR")
    candidates = [
        Path(configured).expanduser() if configured else None,
        repository_root() / "themes",
        Path(sys.prefix) / "share/blox",
        Path("/usr/local/share/blox"),
        Path("/usr/share/blox"),
    ]
    for candidate in candidates:
        if candidate is not None and (candidate / "schema/theme.schema.json").is_file():
            return candidate
    return repository_root() / "themes"


class DefaultsFailure(ValueError):
    """The package defaults document is missing, invalid, or unsupported."""


def defaults_path() -> Path:
    return themes_dir() / "defaults/v1.json"


def load_defaults_document() -> dict[str, Any]:
    path = defaults_path()
    try:
        value = load_json(path)
    except FileNotFoundError as error:
        raise DefaultsFailure(f"defaults document is missing: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise DefaultsFailure(f"defaults document cannot be read: {path}: {error}") from error
    if not isinstance(value, dict):
        raise DefaultsFailure("defaults document root must be an object")
    errors = defaults_schema_errors(value)
    if errors:
        raise DefaultsFailure("invalid defaults document: " + "; ".join(errors))
    return value


def default_bar_items() -> list[dict[str, Any]]:
    return copy.deepcopy(load_defaults_document()["theme"]["shell"]["bar"]["items"])


def default_reset_bar_items() -> list[dict[str, Any]]:
    return copy.deepcopy(load_defaults_document()["theme"]["shell"]["bar"]["reset_items"])


def default_widget_profile(profile: str | None = None) -> dict[str, Any]:
    document = load_defaults_document()
    name = profile or document["widgets"]["profile"]
    try:
        return copy.deepcopy(document["widgets"]["profiles"][name])
    except KeyError as error:
        raise DefaultsFailure(f"defaults document has no widget profile: {name}") from error


def builtin_themes_dir() -> Path:
    return themes_dir() / "builtin"


def is_builtin_theme_path(path: Path) -> bool:
    try:
        path.expanduser().resolve().relative_to(builtin_themes_dir().resolve())
    except ValueError:
        return False
    return True


def user_theme_library() -> Path:
    # Mutable user data stays out of the package tree: the packaging layer
    # installs immutable files to <prefix>/share/blox, which under the
    # default user prefix is ~/.local/share/blox.
    override = os.environ.get("BLOX_USER_DATA_DIR")
    if override:
        return Path(override).expanduser()
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()
    return base / "blox-user"


def resolve_wallpaper_path(value: str, source_path: Path | None = None) -> Path:
    """Resolve a wallpaper reference without changing the source theme.

    Built-in themes use paths relative to the application data directory. A
    theme loaded from elsewhere instead uses its own
    directory, which keeps loose JSON exports usable before they are imported.
    Package-owned built-in wallpaper references retain the package base even
    when a user theme points at them. Absolute and home-relative references
    retain their existing meaning.
    """
    path = Path(value).expanduser()
    if path.is_absolute():
        return path.resolve()
    root = themes_dir()
    if path.parts[:2] == ("wallpapers", "builtin") and ".." not in path.parts:
        return (root / path).resolve()
    if source_path is not None:
        source = source_path.expanduser().resolve()
        try:
            source.relative_to(builtin_themes_dir().resolve())
        except ValueError:
            repository = repository_root().resolve()
            try:
                source.relative_to(repository)
                root = repository
            except ValueError:
                root = source.parent
    return (root / path).resolve()


def state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME")
    return Path(root).expanduser() / "blox-theme" if root else Path.home() / ".local/state/blox-theme"


def canonical_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def theme_path(reference: str) -> Path:
    candidate = Path(reference).expanduser()
    if candidate.is_file() or candidate.suffix == ".json" or "/" in reference:
        return candidate
    built_in = builtin_themes_dir() / f"{reference}.json"
    if built_in.is_file():
        return built_in
    imported = user_theme_library() / "themes" / f"{reference}.json"
    return imported if imported.is_file() else built_in


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


SOURCE_REQUIRED_TOP_LEVEL = ("schema_version", "id", "name", "colours", "wallpaper")
SOURCE_REQUIRED_COLOURS = (
    "background", "surface", "surface_alt", "foreground", "muted", "accent", "danger", "success",
    "warning", "info", "mauve", "teal", "selection_background", "selection_foreground", "border",
)
SOURCE_REQUIRED_WALLPAPER = ("path", "fit")


def source_required_errors(theme: Any) -> list[str]:
    """Return errors for source values that cannot sensibly inherit defaults."""
    if not isinstance(theme, dict):
        return ["$: expected object"]

    errors = [f"$: missing required property {key!r}" for key in SOURCE_REQUIRED_TOP_LEVEL if key not in theme]
    for key, required in (("colours", SOURCE_REQUIRED_COLOURS), ("wallpaper", SOURCE_REQUIRED_WALLPAPER)):
        value = theme.get(key)
        if key not in theme:
            continue
        if not isinstance(value, dict):
            errors.append(f"{key}: expected object")
            continue
        errors.extend(f"{key}: missing required property {child!r}" for child in required if child not in value)
    return errors


def load_theme(reference: str) -> tuple[Path, dict[str, Any]]:
    path = theme_path(reference)
    if not path.is_file():
        raise FileNotFoundError(f"theme not found: {reference}")
    data = load_json(path)
    if not isinstance(data, dict):
        raise ValueError("theme root must be a JSON object")
    return path, apply_theme_defaults(data)


def apply_theme_defaults(theme: dict[str, Any]) -> dict[str, Any]:
    """Resolve a sparse source against the versioned product defaults.

    The source stays sparse. This function only creates the complete view used
    by validation, preview, and target generation. Identity, colours and
    wallpaper must exist in the source; every other omitted value may inherit
    from the versioned canonical defaults.
    """
    required_errors = source_required_errors(theme)
    if required_errors:
        raise ValueError("theme source is incomplete: " + "; ".join(required_errors))
    document = load_defaults_document()
    defaults = document["theme"]
    colours = defaults["colours"]
    fragment: dict[str, Any] = {
        "schema_version": 1,
        "id": defaults["id"],
        "name": defaults.get("name", defaults["id"]),
        "variant": defaults["variant"],
        "colours": {
            "background": colours["background"],
            "surface": colours["surface"],
            "surface_alt": colours["surface_alt"],
            "foreground": colours["foreground"],
            "muted": colours["muted"],
            "danger": colours["red"],
            "success": colours["green"],
            "warning": colours["yellow"],
            "accent": colours["accent"],
            "info": colours["blue"],
            "mauve": colours["mauve"],
            "teal": colours["teal"],
            "selection_background": colours["selection_background"],
            "selection_foreground": colours["selection_foreground"],
            "border": colours["border"],
        },
        "fonts": copy.deepcopy(defaults["fonts"]),
        "shape": copy.deepcopy(defaults["shape"]),
        "hyprland": copy.deepcopy(defaults["hyprland"]),
        "shell": copy.deepcopy(defaults["shell"]),
        "wallpaper": copy.deepcopy(defaults["wallpaper"]),
        "terminal": copy.deepcopy(defaults["terminal"]),
        "stylus": copy.deepcopy(defaults.get("stylus", {"style_set": "recommended"})),
        "widgets": {"profile": document["widgets"]["profile"]},
        "targets": copy.deepcopy(defaults.get("targets", {key: False for key in THEME_TARGET_KEYS})),
    }
    for key in ("gtk", "icons", "cursor"):
        if key in defaults:
            fragment[key] = copy.deepcopy(defaults[key])
    fragment["shell"]["bar"].pop("reset_items", None)

    def merge(base: dict[str, Any], value: dict[str, Any]) -> dict[str, Any]:
        merged = copy.deepcopy(base)
        for key, item in value.items():
            if isinstance(item, dict) and isinstance(merged.get(key), dict):
                merged[key] = merge(merged[key], item)
            else:
                merged[key] = copy.deepcopy(item)
        return merged

    return merge(fragment, theme)


def theme_inherited_paths(source: dict[str, Any], resolved: dict[str, Any], prefix: str = "") -> list[str]:
    """Return resolved paths that were absent from the source document."""
    inherited: list[str] = []
    for key, value in resolved.items():
        path = f"{prefix}.{key}" if prefix else key
        if not isinstance(source, dict) or key not in source:
            inherited.append(path)
        elif isinstance(value, dict) and isinstance(source[key], dict):
            inherited.extend(theme_inherited_paths(source[key], value, path))
    return inherited


def sparsify_theme(
    source: dict[str, Any],
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    touched_paths: Iterable[str] | None = None,
) -> dict[str, Any]:
    """Apply candidate edits to a sparse source without materialising defaults."""
    def update(raw: Any, before: Any, after: Any) -> Any:
        if not isinstance(before, dict) or not isinstance(after, dict):
            return copy.deepcopy(after)

        result = copy.deepcopy(raw) if isinstance(raw, dict) else {}
        for key in set(before) | set(after):
            before_present = key in before
            after_present = key in after
            raw_present = key in result
            if not after_present:
                if raw_present:
                    del result[key]
                continue
            if not before_present:
                result[key] = copy.deepcopy(after[key])
                continue
            if before[key] == after[key]:
                continue
            if isinstance(before[key], dict) and isinstance(after[key], dict):
                child_raw = result.get(key) if isinstance(result.get(key), dict) else {}
                child = update(child_raw, before[key], after[key])
                if child or raw_present:
                    result[key] = child
                else:
                    result.pop(key, None)
            else:
                result[key] = copy.deepcopy(after[key])
        return result

    result = update(source, baseline, candidate)

    def read_path(document: Any, parts: list[str]) -> tuple[bool, Any]:
        value = document
        for part in parts:
            if not isinstance(value, dict) or part not in value:
                return False, None
            value = value[part]
        return True, value

    def write_path(document: dict[str, Any], parts: list[str], value: Any) -> None:
        current = document
        for part in parts[:-1]:
            child = current.get(part)
            if not isinstance(child, dict):
                child = {}
                current[part] = child
            current = child
        current[parts[-1]] = copy.deepcopy(value)

    def delete_path(document: dict[str, Any], parts: list[str]) -> None:
        current = document
        parents: list[tuple[dict[str, Any], str]] = []
        for part in parts[:-1]:
            if not isinstance(current.get(part), dict):
                return
            parents.append((current, part))
            current = current[part]
        current.pop(parts[-1], None)
        for parent, part in reversed(parents):
            if not parent[part]:
                del parent[part]

    for path in touched_paths or ():
        parts = [part for part in str(path).split(".") if part]
        if not parts:
            continue
        exists, value = read_path(candidate, parts)
        if exists:
            write_path(result, parts, value)
        else:
            delete_path(result, parts)
    return result


def list_themes() -> list[dict[str, Any]]:
    entries = []
    paths = [
        *sorted(builtin_themes_dir().glob("*.json")),
        *sorted((user_theme_library() / "themes").glob("*.json")),
    ]
    seen: set[str] = set()
    for path in paths:
        try:
            data = load_json(path)
            if not isinstance(data, dict):
                raise ValueError("theme root must be a JSON object")
            resolved = apply_theme_defaults(data)
            theme_id = resolved.get("id", path.stem)
            if theme_id in seen:
                continue
            seen.add(theme_id)
            wallpaper = resolved.get("wallpaper", {}).get("path", "")
            entries.append(
                {
                    "id": theme_id,
                    "name": resolved.get("name", path.stem),
                    "variant": resolved.get("variant"),
                    "path": str(path),
                    "builtin": is_builtin_theme_path(path),
                    "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "preview": {
                        "colours": resolved.get("colours", {}),
                        "wallpaper": str(resolve_wallpaper_path(wallpaper, path)) if wallpaper else "",
                        "widget_count": sum(
                            1
                            for item in resolved.get("widgets", {}).get("items", [])
                            if isinstance(item, dict) and item.get("enabled", True)
                        ),
                        "fonts": {
                            role: resolved.get("fonts", {}).get(role, "")
                            for role in ("ui", "mono", "panel")
                        },
                        "bar": {
                            "position": resolved.get("shell", {}).get("bar", {}).get("position", "left"),
                            "items": resolved_bar_items(resolved.get("shell", {}).get("bar")),
                        },
                    },
                }
            )
        except (OSError, json.JSONDecodeError, ValueError, DefaultsFailure):
            entries.append({"id": path.stem, "name": path.stem, "variant": None, "path": str(path), "builtin": is_builtin_theme_path(path), "invalid": True})
    return entries


def _resolve_ref(root: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise ValueError(f"unsupported schema reference: {reference}")
    value: Any = root
    for part in reference[2:].split("/"):
        value = value[part.replace("~1", "/").replace("~0", "~")]
    return value


def _basic_schema_errors(instance: Any, schema: dict[str, Any], root: dict[str, Any], path: str = "$") -> list[str]:
    if "$ref" in schema:
        return _basic_schema_errors(instance, _resolve_ref(root, schema["$ref"]), root, path)
    errors: list[str] = []
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: must be one of {schema['enum']}")
    expected = schema.get("type")
    type_checks = {
        "object": isinstance(instance, dict),
        "array": isinstance(instance, list),
        "string": isinstance(instance, str),
        "boolean": isinstance(instance, bool),
        "integer": isinstance(instance, int) and not isinstance(instance, bool),
        "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
        "null": instance is None,
    }
    expected_types = expected if isinstance(expected, list) else [expected]
    type_ok = any(type_checks.get(item, True) for item in expected_types)
    if expected and not type_ok:
        return [f"{path}: expected {expected}"]
    if isinstance(instance, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        if schema.get("additionalProperties") is False:
            for key in instance.keys() - properties.keys():
                errors.append(f"{path}: unknown property {key!r}")
        for key, value in instance.items():
            if key in properties:
                errors.extend(_basic_schema_errors(value, properties[key], root, f"{path}.{key}"))
    elif isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            errors.append(f"{path}: has too few items")
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in instance}) != len(instance):
            errors.append(f"{path}: items must be unique")
        for index, item in enumerate(instance):
            errors.extend(_basic_schema_errors(item, schema.get("items", {}), root, f"{path}[{index}]"))
    elif isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            errors.append(f"{path}: is too short")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            errors.append(f"{path}: is too long")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append(f"{path}: does not match {schema['pattern']}")
    elif isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: must be at least {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: must be at most {schema['maximum']}")
    return errors


def schema_errors(theme: dict[str, Any]) -> list[str]:
    schema = load_json(themes_dir() / "schema/theme.schema.json")
    try:
        import jsonschema

        validator = jsonschema.Draft202012Validator(schema)
        return [f"{'.'.join(str(part) for part in error.absolute_path) or '$'}: {error.message}" for error in sorted(validator.iter_errors(theme), key=lambda item: list(item.absolute_path))]
    except ImportError:
        return _basic_schema_errors(theme, schema, schema)


def defaults_schema_errors(document: dict[str, Any]) -> list[str]:
    schema = load_json(themes_dir() / "schema/defaults.schema.json")
    try:
        import jsonschema

        validator = jsonschema.Draft202012Validator(schema)
        return [f"{'.'.join(str(part) for part in error.absolute_path) or '$'}: {error.message}" for error in sorted(validator.iter_errors(document), key=lambda item: list(item.absolute_path))]
    except ImportError:
        return _basic_schema_errors(document, schema, schema)


# Keep the old public constant for callers that only need the registry shape,
# but load its value from the package document rather than maintaining a copy.
DEFAULT_BAR_ITEMS = tuple(default_bar_items())
DEFAULT_THEME_ID = load_defaults_document()["theme"]["id"]


def _channel(value: int) -> float:
    normalised = value / 255
    return normalised / 12.92 if normalised <= 0.04045 else ((normalised + 0.055) / 1.055) ** 2.4


def contrast_ratio(first: str, second: str) -> float:
    def luminance(colour: str) -> float:
        channels = [_channel(int(colour[index:index + 2], 16)) for index in (1, 3, 5)]
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def _named_asset_exists(name: str, roots: tuple[Path, ...]) -> bool:
    return any((root / name).exists() for root in roots)


def dependency_checks(theme: dict[str, Any], targets: set[str] | None = None, source_path: Path | None = None, apply_gate: bool = True) -> CheckResult:
    """Machine-asset absence blocks an apply outright. Read-only commands
    report the same findings as warnings so a clean machine can still
    validate and render built-ins that reference optional user themes."""
    result = CheckResult()
    asset_findings = result.errors if apply_gate else result.warnings
    enabled = lambda target: theme["targets"][target] and (targets is None or target in targets)
    wallpaper = resolve_wallpaper_path(theme["wallpaper"]["path"], source_path)
    if enabled("wallpaper") and not wallpaper.is_file():
        result.errors.append(f"wallpaper does not exist: {wallpaper}")

    theme_roots = (Path.home() / ".local/share/themes", Path.home() / ".themes", Path("/usr/local/share/themes"), Path("/usr/share/themes"))
    icon_roots = (Path.home() / ".local/share/icons", Path.home() / ".icons", Path("/usr/local/share/icons"), Path("/usr/share/icons"))
    if enabled("gtk") and not _named_asset_exists(theme["gtk"]["base_theme"], theme_roots):
        asset_findings.append(f"GTK base theme is not installed: {theme['gtk']['base_theme']}")
    if (enabled("gtk") or enabled("quickshell")) and not _named_asset_exists(theme["icons"]["theme"], icon_roots):
        asset_findings.append(f"icon theme is not installed: {theme['icons']['theme']}")
    if enabled("zed") and not (shutil.which("zeditor") or shutil.which("zed")):
        asset_findings.append("Zed is not installed; install the zeditor CLI before applying the Zed target")
    if enabled("obsidian") and not shutil.which("obsidian"):
        asset_findings.append("Obsidian is not installed; install the Obsidian desktop CLI before applying the Obsidian target")
    cursor = theme["cursor"]
    if enabled("cursor"):
        if cursor["mode"] == "installed" and not _named_asset_exists(cursor["base"], icon_roots):
            asset_findings.append(f"cursor base is not installed: {cursor['base']}")
        elif cursor["mode"] == "generated":
            from .cursor import toolchain_check

            check = toolchain_check()
            if not check["ok"]:
                severity = result.errors if targets is not None and "cursor" in targets else result.warnings
                severity.append(f"cursor toolchain is not installed; run: {check['recovery']}")

    font_targets = ("quickshell", "widgets", "gtk", "kitty", "btop", "micro", "glow", "code", "cursor_editor", "stylus", "powerlevel10k", "sddm", "grub")
    fonts_enabled = any(enabled(target) for target in font_targets)
    if fonts_enabled and shutil.which("fc-match"):
        for role in ("ui", "mono", "panel"):
            requested = theme["fonts"][role]
            matched = subprocess.run(["fc-match", "-f", "%{family}", requested], check=False, capture_output=True, text=True).stdout.split(",", 1)[0]
            if matched.casefold() != requested.casefold():
                result.warnings.append(f"font {requested!r} resolves to {matched!r}")
    elif fonts_enabled:
        result.warnings.append("fc-match is unavailable; font dependencies were not checked")
    return result


def validate_theme(
    theme: dict[str, Any],
    check_dependencies: bool = True,
    targets: set[str] | None = None,
    source_path: Path | None = None,
    dependency_gate: bool = True,
) -> CheckResult:
    result = CheckResult(errors=schema_errors(theme))
    if result.errors:
        return result
    bar_items = theme.get("shell", {}).get("bar", {}).get("items", [])
    bar_item_ids = [item["id"] for item in bar_items]
    if len(bar_item_ids) != len(set(bar_item_ids)):
        result.errors.append("shell.bar.items must not contain duplicate item ids")
    widget_items = theme.get("widgets", {}).get("items", [])
    widget_ids = [item["id"] for item in widget_items]
    if len(widget_ids) != len(set(widget_ids)):
        result.errors.append("widgets.items must not contain duplicate widget ids")
    colours = theme["colours"]
    pairs = (
        ("foreground", "background", 4.5),
        ("foreground", "surface", 4.5),
        ("muted", "background", 4.5),
        ("selection_foreground", "selection_background", 4.5),
        ("accent", "background", 3.0),
    )
    for foreground, background, minimum in pairs:
        ratio = contrast_ratio(colours[foreground], colours[background])
        if ratio < minimum:
            result.warnings.append(f"{foreground}/{background} contrast is {ratio:.2f}:1; recommends {minimum:.1f}:1")
    from .cursor import validate_cursor_theme

    cursor_errors, cursor_warnings = validate_cursor_theme(theme)
    result.errors.extend(cursor_errors)
    result.warnings.extend(cursor_warnings)
    generator = theme.get("generator")
    if generator:
        options = generator["options"]
        if options["mode"] != theme["variant"]:
            result.errors.append("generator options.mode must match the theme variant")
        backend_keys = {
            "matugen": {"mode", "scheme", "contrast", "source_colour_index"},
            "pywal": {"mode", "saturation"},
        }
        expected = backend_keys[generator["backend"]]
        if generator["backend"] == "matugen" and set(options) != expected:
            result.errors.append("matugen generator options must contain mode, scheme, contrast, and source_colour_index only")
        if generator["backend"] == "pywal" and not set(options).issubset(expected):
            result.errors.append("pywal generator options may contain mode and saturation only")
    gtk_override = theme.get("overrides", {}).get("gtk")
    if theme["gtk"]["mode"] == "generated" and theme["gtk"]["colour_source"] == "override" and not gtk_override:
        result.errors.append("generated GTK override colour source requires overrides.gtk")
    if theme["gtk"]["mode"] == "installed" and gtk_override:
        result.warnings.append("overrides.gtk is ignored in installed GTK mode")
    if theme["targets"]["gtk"] and theme["gtk"]["mode"] == "generated":
        gtk_colours = target_colours(theme, "gtk")
        for foreground, background, minimum in (("foreground", "background", 4.5), ("selection_foreground", "selection_background", 4.5), ("accent", "background", 3.0)):
            ratio = contrast_ratio(gtk_colours[foreground], gtk_colours[background])
            if ratio < minimum:
                result.warnings.append(f"GTK override {foreground}/{background} contrast is {ratio:.2f}:1; recommends {minimum:.1f}:1")
    if check_dependencies:
        dependencies = dependency_checks(theme, targets=targets, source_path=source_path, apply_gate=dependency_gate)
        result.errors.extend(dependencies.errors)
        result.warnings.extend(dependencies.warnings)
    return result


def derive_ansi(theme: dict[str, Any]) -> dict[str, str]:
    colours = theme["colours"]
    roles = ("surface", "danger", "success", "warning", "info", "mauve", "teal", "muted", "surface_alt", "danger", "success", "warning", "info", "mauve", "teal", "foreground")
    derived = {f"color{index}": colours[role].lower() for index, role in enumerate(roles)}
    derived.update({key: value.lower() for key, value in theme.get("overrides", {}).get("ansi", {}).items()})
    return derived


def target_colours(theme: dict[str, Any], target: str) -> dict[str, str]:
    colours = {key: value.lower() for key, value in theme["colours"].items()}
    colours.update({key: value.lower() for key, value in theme.get("overrides", {}).get(target, {}).items()})
    return colours


def round_scaled(base: int, scale: float) -> int:
    """Round a non-negative scaled token like QML's Math.round."""
    return math.floor(base * scale + 0.5)


def derive_shape(theme: dict[str, Any]) -> dict[str, int | float | None]:
    """Resolve the file-backed shape values from the source scale fields."""
    shape = theme["shape"]
    hyprland = theme.get("hyprland") or {}
    radius_scale = shape["radius_scale"]
    density_scale = shape["density_scale"]
    automatic_gap = max(0, math.floor(AUTOMATIC_GAP_BASE * (density_scale - MINIMUM_DENSITY_SCALE) + 0.5))
    window_gap = shape.get("window_gap")
    return {
        "radius_scale": radius_scale,
        "density_scale": density_scale,
        "window_gap": window_gap,
        "hyprland_rounding": round_scaled(HYPRLAND_RADIUS_BASE, radius_scale),
        "hyprland_gap": automatic_gap if window_gap is None else window_gap,
        "hyprland_inactive_opacity": hyprland.get("inactive_opacity", 1.0),
        "hyprland_border_size": hyprland.get("border_size", 1),
        "gtk_radius": round_scaled(GTK_RADIUS_BASE, radius_scale),
    }


def render_quickshell(theme: dict[str, Any], ansi: dict[str, str]) -> str:
    colours = target_colours(theme, "quickshell")
    shell = copy.deepcopy(theme.get("shell") or load_defaults_document()["theme"]["shell"])
    shell = {**shell, "bar": {**shell.get("bar", {}), "items": resolved_bar_items(shell.get("bar"))}}
    output = {
        "schema_version": 1,
        "id": theme["id"],
        "variant": theme["variant"],
        "colours": colours,
        "compatibility": {"red": colours["danger"], "green": colours["success"], "yellow": colours["warning"], "blue": colours["info"], "mauve": colours["mauve"], "teal": colours["teal"]},
        "fonts": {"ui": theme["fonts"]["ui"], "mono": theme["fonts"]["mono"], "panel": theme["fonts"]["panel"]},
        "shape": copy.deepcopy(theme["shape"]),
        "icons": copy.deepcopy(theme["icons"]),
        "terminal": copy.deepcopy(theme["terminal"]),
        "ansi": ansi,
        "shell": shell,
    }
    return canonical_json(output)


def render_kitty(theme: dict[str, Any], ansi: dict[str, str]) -> str:
    colours = theme["colours"]
    terminal = theme["terminal"]
    lines = [
        "# Generated by themectl; edit the source theme, not this file.",
        f"foreground {colours['foreground'].lower()}", f"background {terminal['canvas'].lower()}",
        f"selection_foreground {colours['selection_foreground'].lower()}", f"selection_background {colours['selection_background'].lower()}",
        f"cursor {colours['accent'].lower()}", f"cursor_text_color {colours['selection_foreground'].lower()}", f"url_color {colours['info'].lower()}",
        f"active_border_color {colours['accent'].lower()}", f"inactive_border_color {colours['border'].lower()}", f"bell_border_color {colours['danger'].lower()}",
        f"active_tab_foreground {colours['background'].lower()}", f"active_tab_background {colours['foreground'].lower()}",
        f"inactive_tab_foreground {colours['foreground'].lower()}", f"inactive_tab_background {terminal['canvas'].lower()}",
        "tab_bar_background none", "",
    ]
    lines.extend(f"{key} {value}" for key, value in ansi.items())
    return "\n".join(lines) + "\n"


def render_wallpaper(theme: dict[str, Any], source_path: Path | None = None) -> str:
    reference = theme["wallpaper"]["path"]
    rendered_path = reference if Path(reference).expanduser().is_absolute() else str(resolve_wallpaper_path(reference, source_path))
    return canonical_json(
        {
            "schema_version": 1,
            "path": rendered_path,
            "fit": theme["wallpaper"]["fit"],
        }
    )


def render_gtk_settings(theme: dict[str, Any]) -> str:
    cursor_size = theme["cursor"]["sizes"][0]
    cursor_name = "blox-generated" if theme["cursor"]["mode"] == "generated" else theme["cursor"]["base"]
    prefer_dark = 1 if theme["variant"] == "dark" else 0
    lines = [
        "[Settings]",
        f"gtk-theme-name={theme['gtk']['base_theme']}",
        f"gtk-icon-theme-name={theme['icons']['theme']}",
        f"gtk-font-name={theme['fonts']['ui']} {theme['fonts']['gtk_size']}",
        f"gtk-cursor-theme-name={cursor_name}",
        f"gtk-cursor-theme-size={cursor_size}",
        f"gtk-application-prefer-dark-theme={prefer_dark}",
    ]
    return "\n".join(lines) + "\n"


def _gtk_definitions(theme: dict[str, Any]) -> str:
    colours = target_colours(theme, "gtk")
    roles = {
        "blox_bg": colours["background"],
        "blox_surface": colours["surface"],
        "blox_surface_alt": colours["surface_alt"],
        "blox_fg": colours["foreground"],
        "blox_muted": colours["muted"],
        "blox_accent": colours["accent"],
        "blox_selection_bg": colours["selection_background"],
        "blox_selection_fg": colours["selection_foreground"],
        "blox_border": colours["border"],
        "blox_success": colours["success"],
        "blox_warning": colours["warning"],
        "blox_danger": colours["danger"],
    }
    aliases = {
        "theme_bg_color": "blox_bg",
        "theme_fg_color": "blox_fg",
        "theme_base_color": "blox_surface",
        "theme_text_color": "blox_fg",
        "theme_selected_bg_color": "blox_selection_bg",
        "theme_selected_fg_color": "blox_selection_fg",
        "accent_bg_color": "blox_accent",
        "accent_fg_color": "blox_selection_fg",
        "success_color": "blox_success",
        "warning_color": "blox_warning",
        "error_color": "blox_danger",
    }
    lines = ["/* Generated by themectl; edit the source theme, not this file. */"]
    lines.extend(f"@define-color {name} {value};" for name, value in roles.items())
    lines.extend(f"@define-color {name} @{source};" for name, source in aliases.items())
    return "\n".join(lines)


def render_gtk3(theme: dict[str, Any]) -> str:
    radius = derive_shape(theme)["gtk_radius"]
    css = """

window,
.background,
.gtkstyle-fallback {
  background-color: @blox_bg;
  color: @blox_fg;
}

headerbar,
.titlebar,
toolbar,
menubar,
menu {
  background-color: @blox_surface;
  color: @blox_fg;
  border-color: @blox_border;
}

button,
entry,
spinbutton,
combobox box.linked button {
  background-image: none;
  background-color: @blox_surface;
  color: @blox_fg;
  border-color: @blox_border;
  border-radius: __BLOX_RADIUS__px;
}

button:hover,
row:hover,
menuitem:hover {
  background-image: none;
  background-color: @blox_surface_alt;
}

button:checked,
button:active,
switch:checked,
scale highlight,
progressbar progress {
  background-image: none;
  background-color: @blox_accent;
  color: @blox_selection_fg;
  border-color: @blox_accent;
}

entry selection,
label selection,
textview text selection,
treeview.view:selected,
row:selected {
  background-color: @blox_selection_bg;
  color: @blox_selection_fg;
}

textview text,
iconview,
.view {
  background-color: @blox_surface;
  color: @blox_fg;
}

*:disabled {
  color: @blox_muted;
}

*:focus {
  outline-color: @blox_accent;
}

.success { color: @blox_success; }
.warning { color: @blox_warning; }
.error { color: @blox_danger; }
"""
    return _gtk_definitions(theme) + css.replace("__BLOX_RADIUS__", str(radius))


def render_gtk4(theme: dict[str, Any]) -> str:
    radius = derive_shape(theme)["gtk_radius"]
    css = """

window {
  background-color: @blox_bg;
  color: @blox_fg;
}

headerbar,
.titlebar,
toolbar,
popover > contents,
menu {
  background-color: @blox_surface;
  color: @blox_fg;
  border-color: @blox_border;
}

button,
entry,
spinbutton,
dropdown > button {
  background-image: none;
  background-color: @blox_surface;
  color: @blox_fg;
  border-color: @blox_border;
  border-radius: __BLOX_RADIUS__px;
}

button:hover,
row:hover {
  background-image: none;
  background-color: @blox_surface_alt;
}

button:checked,
button:active,
switch:checked,
scale highlight,
progressbar progress {
  background-image: none;
  background-color: @blox_accent;
  color: @blox_selection_fg;
  border-color: @blox_accent;
}

entry selection,
label selection,
textview text selection,
columnview row:selected,
listview row:selected,
gridview > child:selected {
  background-color: @blox_selection_bg;
  color: @blox_selection_fg;
}

textview text,
.view {
  background-color: @blox_surface;
  color: @blox_fg;
}

*:disabled {
  color: @blox_muted;
}

*:focus-visible {
  outline-color: @blox_accent;
}

.success { color: @blox_success; }
.warning { color: @blox_warning; }
.error { color: @blox_danger; }
"""
    return _gtk_definitions(theme) + css.replace("__BLOX_RADIUS__", str(radius))


def render_gtk(theme: dict[str, Any]) -> dict[str, str]:
    settings = render_gtk_settings(theme)
    metadata = {
        "schema_version": 1,
        "mode": theme["gtk"]["mode"],
        "base_theme": theme["gtk"]["base_theme"],
        "font": f"{theme['fonts']['ui']} {theme['fonts']['gtk_size']}",
        "generated_css": theme["gtk"]["mode"] == "generated",
        "restart_required": True,
        "libadwaita_support": "partial-user-css",
    }
    files = {
        "gtk/gtk-3.0/settings.ini": settings,
        "gtk/gtk-4.0/settings.ini": settings,
        "gtk/metadata.json": canonical_json(metadata),
    }
    if theme["gtk"]["mode"] == "generated":
        files["gtk/gtk-3.0/gtk.css"] = render_gtk3(theme)
        files["gtk/gtk-4.0/gtk.css"] = render_gtk4(theme)
    return files


def _rgba(colour: str, alpha: str = "ff") -> str:
    return colour.removeprefix("#").lower() + alpha


def render_hyprland(theme: dict[str, Any]) -> str:
    c = theme["colours"]
    shape = derive_shape(theme)
    return """-- Generated by themectl; edit the source theme, not this file.
hl.config({
    general = {
        border_size = %d,
        gaps_in = %d,
        gaps_out = %d,
        col = {
            active_border = \"rgba(%s)\",
            inactive_border = \"rgba(%s)\",
        },
    },
    decoration = {
        rounding = %d,
        inactive_opacity = %.2f,
        shadow = { color = \"rgba(%s)\" },
    },
})
""" % (shape["hyprland_border_size"], shape["hyprland_gap"], shape["hyprland_gap"], _rgba(c["accent"], "ee"), _rgba(c["border"], "aa"), shape["hyprland_rounding"], shape["hyprland_inactive_opacity"], _rgba(c["background"], "ee"))


def render_hyprtoolkit(theme: dict[str, Any]) -> str:
    c = theme["colours"]

    def argb(colour: str) -> str:
        return f"0xFF{colour.removeprefix('#').upper()}"

    return """# Generated by themectl; edit the source theme, not this file.
background = %s
base = %s
text = %s
alternate_base = %s
bright_text = %s
accent = %s
accent_secondary = %s
icon_theme = %s
font_family = %s
font_family_monospace = %s
""" % (
        argb(c["background"]),
        argb(c["surface"]),
        argb(c["foreground"]),
        argb(c["surface_alt"]),
        argb(c["foreground"]),
        argb(c["accent"]),
        argb(c["info"]),
        theme["icons"]["theme"],
        theme["fonts"]["ui"],
        theme["fonts"]["mono"],
    )


def render_hyprlock(theme: dict[str, Any]) -> str:
    c = target_colours(theme, "hyprlock")
    values = {
        "font": theme["fonts"]["panel"], "background": _rgba(c["background"], "cc"),
        "surface": _rgba(c["surface"], "e6"), "surface_alt": _rgba(c["surface_alt"]),
        "foreground": c["foreground"].removeprefix("#"), "muted": c["muted"].removeprefix("#"),
        "red": c["danger"].removeprefix("#"), "yellow": c["warning"].removeprefix("#"),
        "blue": c["accent"].removeprefix("#"),
    }
    return "# Generated by themectl; edit the source theme, not this file.\n" + "\n".join(f"${key} = {'rgba' if key in {'background', 'surface', 'surface_alt'} else 'rgb'}({value})" if key != "font" else f"$font = {value}" for key, value in values.items()) + "\n"


def render_btop(theme: dict[str, Any]) -> str:
    c = theme["colours"]
    roles = {
        "main_bg": "background", "main_fg": "foreground", "title": "foreground", "hi_fg": "accent",
        "selected_bg": "selection_background", "selected_fg": "selection_foreground", "inactive_fg": "muted",
        "proc_misc": "info", "cpu_box": "border", "mem_box": "border", "net_box": "border", "proc_box": "border", "div_line": "border",
        "temp_start": "success", "temp_mid": "warning", "temp_end": "danger", "cpu_start": "success", "cpu_mid": "warning", "cpu_end": "danger",
        "free_start": "info", "free_mid": "mauve", "free_end": "teal", "cached_start": "info", "cached_mid": "mauve", "cached_end": "danger",
        "available_start": "info", "available_mid": "mauve", "available_end": "success", "used_start": "success", "used_mid": "warning", "used_end": "danger",
        "download_start": "info", "download_mid": "mauve", "download_end": "teal", "upload_start": "teal", "upload_mid": "mauve", "upload_end": "info",
    }
    return "# Generated by themectl; edit the source theme, not this file.\n" + "\n".join(f'theme[{key}]="{c[role].lower()}"' for key, role in roles.items()) + "\n"


def render_micro(theme: dict[str, Any]) -> str:
    c = theme["colours"]
    links = {
        "default": c["foreground"], "comment": c["muted"], "identifier": c["foreground"],
        "constant": c["mauve"], "statement": c["accent"], "symbol": c["teal"], "preproc": c["warning"],
        "type": c["success"], "special": c["info"], "underlined": c["info"], "error": c["danger"],
        "todo": f'{c["background"]},{c["warning"]}', "statusline": f'{c["foreground"]},{c["surface_alt"]}',
        "tabbar": f'{c["muted"]},{c["surface"]}', "indent-char": c["border"], "selection": f'{c["selection_foreground"]},{c["selection_background"]}',
    }
    return "# Generated by themectl; edit the source theme, not this file.\n" + "\n".join(f'color-link {key} \"{value.lower()}\"' for key, value in links.items()) + "\n"


def render_glow(theme: dict[str, Any]) -> str:
    c = theme["colours"]
    colour = lambda role: c[role].lower()
    style = {
        "document": {"block_prefix": "", "block_suffix": "", "color": colour("foreground")},
        "heading": {"block_suffix": "\n", "color": colour("accent"), "bold": True},
        "paragraph": {"color": colour("foreground")}, "text": {"color": colour("foreground")},
        "link": {"color": colour("info"), "underline": True}, "link_text": {"color": colour("accent")},
        "code": {"color": colour("teal")}, "code_block": {"color": colour("foreground"), "background_color": colour("surface")},
        "blockquote": {"color": colour("muted"), "indent": 1, "indent_token": "│ "},
        "list": {"color": colour("foreground")}, "item": {"block_prefix": "• "},
    }
    return canonical_json(style)


def editor_colours(theme: dict[str, Any]) -> dict[str, str]:
    c = theme["colours"]
    custom = {
        "editor.background": c["background"], "editor.foreground": c["foreground"], "editor.selectionBackground": c["selection_background"],
        "editor.inactiveSelectionBackground": c["surface_alt"], "editorCursor.foreground": c["accent"], "editorLineNumber.foreground": c["muted"],
        "editorGroupHeader.tabsBackground": c["surface"], "editorGroup.border": c["border"],
        "tab.activeBackground": c["background"], "tab.activeForeground": c["foreground"], "tab.activeBorderTop": c["accent"],
        "tab.inactiveBackground": c["surface"], "tab.inactiveForeground": c["muted"], "tab.border": c["border"],
        "activityBar.background": c["surface"], "activityBar.foreground": c["foreground"], "activityBar.inactiveForeground": c["muted"],
        "activityBar.border": c["border"], "activityBarBadge.background": c["accent"], "activityBarBadge.foreground": c["background"],
        "sideBar.background": c["surface"], "sideBar.foreground": c["foreground"], "sideBar.border": c["border"],
        "sideBarTitle.foreground": c["foreground"], "sideBarSectionHeader.background": c["surface_alt"],
        "sideBarSectionHeader.foreground": c["foreground"], "sideBarSectionHeader.border": c["border"],
        "list.activeSelectionBackground": c["selection_background"], "list.activeSelectionForeground": c["selection_foreground"],
        "list.inactiveSelectionBackground": c["surface_alt"], "list.inactiveSelectionForeground": c["foreground"],
        "list.hoverBackground": c["surface_alt"], "list.hoverForeground": c["foreground"], "list.focusOutline": c["accent"],
        "gitDecoration.addedResourceForeground": c["success"], "gitDecoration.modifiedResourceForeground": c["warning"],
        "gitDecoration.deletedResourceForeground": c["danger"], "gitDecoration.untrackedResourceForeground": c["teal"],
        "panel.background": c["surface"], "panel.border": c["border"], "panelTitle.activeForeground": c["foreground"],
        "panelTitle.inactiveForeground": c["muted"], "panelTitle.activeBorder": c["accent"],
        "titleBar.activeBackground": c["surface"], "titleBar.activeForeground": c["foreground"], "titleBar.border": c["border"],
        "statusBar.background": c["surface_alt"], "statusBar.foreground": c["foreground"], "statusBar.border": c["border"],
        "input.background": c["background"], "input.foreground": c["foreground"], "input.border": c["border"],
        "dropdown.background": c["surface_alt"], "dropdown.foreground": c["foreground"], "dropdown.border": c["border"],
        "menu.background": c["surface"], "menu.foreground": c["foreground"], "menu.selectionBackground": c["selection_background"],
        "badge.background": c["accent"], "badge.foreground": c["background"],
        "focusBorder": c["accent"], "errorForeground": c["danger"],
    }
    return custom


EDITOR_THEME_PACKAGE_NAME = "blox-theme"
EDITOR_THEME_PUBLISHER = "blox"
EDITOR_THEME_VERSION = "1.0.0"
EDITOR_THEME_LABEL_PREFIX = "Blox: "
EDITOR_THEME_RELATIVE_PATH = "themes/blox-generated-color-theme.json"
EDITOR_MINIMUM_VERSION = "^1.90.0"


def editor_theme_label(theme: dict[str, Any]) -> str:
    return f"{EDITOR_THEME_LABEL_PREFIX}{theme['name']}"


def editor_theme_setting_value(theme: dict[str, Any]) -> str:
    """Return the generated package id that Code uses to restore the theme."""
    return EDITOR_THEME_PACKAGE_NAME


def editor_modern_ui_value(theme: dict[str, Any]) -> bool:
    """Map Blox's square/rounded boundary to Code's binary UI mode."""
    return theme["shape"]["radius_scale"] > 0


def _vscode_source_path(variant: str) -> Path:
    if variant not in ("dark", "light"):
        raise ValueError(f"unsupported VS Code theme variant: {variant}")
    return themes_dir() / "sources/vscode" / f"2026-{variant}.json"


def _merge_vscode_theme(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(base)
    for key, value in overlay.items():
        if key == "include":
            continue
        if key == "colors":
            colours = dict(merged.get(key, {}))
            colours.update(value)
            merged[key] = colours
        elif key == "semanticTokenColors":
            semantic = dict(merged.get(key, {}))
            semantic.update(value)
            merged[key] = semantic
        elif key == "tokenColors":
            merged[key] = list(merged.get(key, [])) + list(value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def _load_vscode_theme(path: Path, stack: tuple[Path, ...] = ()) -> dict[str, Any]:
    path = path.resolve()
    source_root = (themes_dir() / "sources/vscode").resolve()
    try:
        path.relative_to(source_root)
    except ValueError as error:
        raise ValueError(f"VS Code theme include escapes the pinned source directory: {path}") from error
    if path in stack:
        raise ValueError(f"cyclic VS Code theme include: {path}")
    document = load_json(path)
    if not isinstance(document, dict):
        raise ValueError(f"VS Code theme source must be an object: {path}")
    include = document.get("include")
    parent: dict[str, Any] = {}
    if include is not None:
        if not isinstance(include, str):
            raise ValueError(f"VS Code theme include must be a path: {path}")
        parent = _load_vscode_theme(path.parent / include, (*stack, path))
    return _merge_vscode_theme(parent, document)


def _editor_token_colours(theme: dict[str, Any]) -> list[dict[str, Any]]:
    c = theme["colours"]
    return [
        {"scope": ["comment", "punctuation.definition.comment"], "settings": {"foreground": c["muted"]}},
        {"scope": ["keyword", "storage", "storage.type"], "settings": {"foreground": c["danger"]}},
        {"scope": ["string", "string.quoted"], "settings": {"foreground": c["info"]}},
        {"scope": ["entity.name.function", "support.function"], "settings": {"foreground": c["mauve"]}},
        {"scope": ["entity.name.tag", "support.class.component", "entity.name.type", "support.type"], "settings": {"foreground": c["success"]}},
        {"scope": ["constant", "support", "meta.property-name"], "settings": {"foreground": c["info"]}},
        {"scope": ["variable", "variable.other", "meta.object.member"], "settings": {"foreground": c["foreground"]}},
        {"scope": ["constant.numeric", "constant.language"], "settings": {"foreground": c["warning"]}},
        {"scope": ["string.regexp", "source.regexp"], "settings": {"foreground": c["teal"]}},
        {"scope": ["invalid", "invalid.illegal", "invalid.deprecated"], "settings": {"foreground": c["danger"], "fontStyle": "italic"}},
        {"scope": ["markup.heading", "markup.heading entity.name"], "settings": {"foreground": c["accent"], "fontStyle": "bold"}},
        {"scope": ["markup.italic"], "settings": {"foreground": c["foreground"], "fontStyle": "italic"}},
        {"scope": ["markup.bold"], "settings": {"foreground": c["foreground"], "fontStyle": "bold"}},
    ]


def _editor_theme(theme: dict[str, Any]) -> dict[str, Any]:
    source = _load_vscode_theme(_vscode_source_path(theme["variant"]))
    colours = dict(source.get("colors", {}))
    colours.update(editor_colours(theme))
    semantic = dict(source.get("semanticTokenColors", {}))
    c = theme["colours"]
    semantic.update({
        "comment": c["muted"], "keyword": c["danger"], "string": c["info"],
        "function": c["mauve"], "class": c["success"], "type": c["success"],
        "variable": c["foreground"], "property": c["teal"], "number": c["warning"],
        "enumMember": c["info"],
    })
    return {
        "$schema": "vscode://schemas/color-theme",
        "name": editor_theme_label(theme),
        "type": theme["variant"],
        "semanticHighlighting": True,
        "colors": colours,
        "tokenColors": list(source.get("tokenColors", [])) + _editor_token_colours(theme),
        "semanticTokenColors": semantic,
    }


def _editor_package(theme: dict[str, Any]) -> str:
    package = {
        "name": EDITOR_THEME_PACKAGE_NAME,
        "displayName": "Blox editor theme",
        "description": "Generated Blox colour and syntax theme.",
        "version": EDITOR_THEME_VERSION,
        "publisher": EDITOR_THEME_PUBLISHER,
        "engines": {"vscode": EDITOR_MINIMUM_VERSION},
        "categories": ["Themes"],
        "contributes": {"themes": [{
            "id": EDITOR_THEME_PACKAGE_NAME,
            "label": editor_theme_label(theme),
            "uiTheme": "vs-dark" if theme["variant"] == "dark" else "vs",
            "path": f"./{EDITOR_THEME_RELATIVE_PATH}",
        }]},
    }
    return canonical_json(package)


def render_editor(theme: dict[str, Any]) -> str:
    """Render Code's settings fragment alongside the generated package."""
    return canonical_json({
        "workbench.colorTheme": editor_theme_setting_value(theme),
        "workbench.experimental.modernUI": editor_modern_ui_value(theme),
        "editor.fontFamily": theme["fonts"]["mono"],
    })


def render_cursor_editor(theme: dict[str, Any]) -> str:
    """Render Cursor's settings fragment without unsupported Code settings."""
    return canonical_json({
        "workbench.colorTheme": editor_theme_setting_value(theme),
        "editor.fontFamily": theme["fonts"]["mono"],
    })


def render_t3code(theme: dict[str, Any]) -> str:
    """Render T3Code's supported environment-theme document.

    T3Code does not consume the VS Code theme format. Its environment route
    accepts a palette keyed by T3Code's semantic colour roles, so keep this
    projection separate from the Code and Cursor packages.
    """
    c = theme["colours"]
    colours = {
        "canvas": c["background"],
        "chrome": c["background"],
        "toolbar": c["background"],
        "toolbarForeground": c["foreground"],
        "toolbarBorder": c["border"],
        "toolbarControl": c["surface_alt"],
        "toolbarControlForeground": c["foreground"],
        "toolbarControlHover": c["surface_alt"],
        "surface": c["surface"],
        "surfaceRaised": c["surface_alt"],
        "surfaceOverlay": c["surface_alt"],
        "text": c["foreground"],
        "textMuted": c["muted"],
        "border": c["border"],
        "input": c["surface_alt"],
        "focus": c["accent"],
        "accent": c["accent"],
        "accentForeground": c["selection_foreground"],
        "secondary": c["surface"],
        "secondaryForeground": c["foreground"],
        "muted": c["surface"],
        "mutedForeground": c["muted"],
        "placeholder": c["muted"],
        "secondaryLabel": c["muted"],
        "iconMuted": c["muted"],
        "error": c["danger"],
        "errorForeground": c["danger"],
        "errorSurface": c["surface_alt"],
        "warning": c["warning"],
        "warningForeground": c["warning"],
        "warningSurface": c["surface_alt"],
        "update": c["info"],
        "updateForeground": c["info"],
        "updateSurface": c["surface_alt"],
        "accentSurface": c["selection_background"],
        "accentSurfaceForeground": c["selection_foreground"],
        "messageSurface": c["surface_alt"],
        "messageForeground": c["foreground"],
        "messageAction": c["accent"],
        "messageActionForeground": c["selection_foreground"],
        "messageActionHover": c["info"],
        "codeBackground": c["background"],
        "codeForeground": c["foreground"],
        "sidebar": c["surface"],
        "sidebarForeground": c["foreground"],
        "sidebarMutedForeground": c["muted"],
        "sidebarControlSurface": c["surface_alt"],
        "sidebarRowHover": c["surface_alt"],
        "sidebarRowActive": c["surface_alt"],
        "sidebarRowSelected": c["selection_background"],
        "sidebarBorder": c["border"],
        "terminalBackground": c["background"],
        "terminalForeground": c["foreground"],
        "terminalCursor": c["accent"],
        "terminalSelection": c["selection_background"],
        "terminalScrollbar": c["border"],
        "terminalScrollbarHover": c["muted"],
    }
    return canonical_json({
        "version": 1,
        "name": theme["name"],
        "appearance": theme["variant"],
        "canvas": c["background"],
        "accent": c["accent"],
        "colors": colours,
    })


def zed_theme_label(theme: dict[str, Any]) -> str:
    return f"Blox: {theme['name']}"


def render_zed(theme: dict[str, Any]) -> str:
    """Render Zed's native theme-family format from the resolved theme."""
    c = target_colours(theme, "zed")
    ansi = derive_ansi(theme)
    style = {
        "accents": [c["accent"]],
        "background": c["background"],
        "background.appearance": "opaque",
        "border": c["border"],
        "border.disabled": c["surface_alt"],
        "border.focused": c["accent"],
        "border.selected": c["accent"],
        "border.transparent": c["surface"],
        "border.variant": c["surface_alt"],
        "conflict": c["danger"],
        "conflict.background": c["surface_alt"],
        "conflict.border": c["danger"],
        "created": c["success"],
        "created.background": c["surface_alt"],
        "created.border": c["success"],
        "deleted": c["danger"],
        "deleted.background": c["surface_alt"],
        "deleted.border": c["danger"],
        "drop_target.background": c["selection_background"],
        "editor.active_line.background": c["surface"],
        "editor.active_line_number": c["foreground"],
        "editor.background": c["background"],
        "editor.foreground": c["foreground"],
        "editor.gutter.background": c["background"],
        "editor.highlighted_line.background": c["surface"],
        "editor.indent_guide": c["border"],
        "editor.indent_guide_active": c["accent"],
        "editor.invisible": c["muted"],
        "editor.line_number": c["muted"],
        "element.active": c["selection_background"],
        "element.background": c["surface_alt"],
        "element.disabled": c["surface"],
        "element.hover": c["surface_alt"],
        "element.selected": c["selection_background"],
        "elevated_surface.background": c["surface_alt"],
        "error": c["danger"],
        "error.background": c["surface_alt"],
        "error.border": c["danger"],
        "ghost_element.active": c["selection_background"],
        "ghost_element.background": c["surface"],
        "ghost_element.disabled": c["surface"],
        "ghost_element.hover": c["surface_alt"],
        "ghost_element.selected": c["selection_background"],
        "hidden": c["muted"],
        "hidden.background": c["surface"],
        "hidden.border": c["border"],
        "hint": c["info"],
        "hint.background": c["surface_alt"],
        "hint.border": c["info"],
        "icon": c["foreground"],
        "icon.accent": c["accent"],
        "icon.disabled": c["muted"],
        "icon.muted": c["muted"],
        "icon.placeholder": c["muted"],
        "info": c["info"],
        "info.background": c["surface_alt"],
        "info.border": c["info"],
        "link_text.hover": c["accent"],
        "modified": c["warning"],
        "modified.background": c["surface_alt"],
        "modified.border": c["warning"],
        "pane.focused_border": c["accent"],
        "pane_group.border": c["border"],
        "panel.background": c["surface"],
        "panel.focused_border": c["accent"],
        "scrollbar.thumb.background": c["border"],
        "scrollbar.thumb.border": c["border"],
        "scrollbar.thumb.hover_background": c["muted"],
        "scrollbar.track.background": c["background"],
        "scrollbar.track.border": c["background"],
        "search.match_background": c["warning"],
        "status_bar.background": c["surface"],
        "success": c["success"],
        "success.background": c["surface_alt"],
        "success.border": c["success"],
        "surface.background": c["surface"],
        "tab.active_background": c["surface_alt"],
        "tab.inactive_background": c["background"],
        "tab_bar.background": c["background"],
        "terminal.ansi.background": c["background"],
        "terminal.background": c["background"],
        "terminal.bright_foreground": c["foreground"],
        "terminal.dim_foreground": c["muted"],
        "terminal.foreground": c["foreground"],
        "text": c["foreground"],
        "text.accent": c["accent"],
        "text.disabled": c["muted"],
        "text.muted": c["muted"],
        "text.placeholder": c["muted"],
        "title_bar.background": c["background"],
        "title_bar.inactive_background": c["background"],
        "toolbar.background": c["surface"],
        "unreachable": c["danger"],
        "unreachable.background": c["surface_alt"],
        "unreachable.border": c["danger"],
        "warning": c["warning"],
        "warning.background": c["surface_alt"],
        "warning.border": c["warning"],
    }
    ansi_names = (
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "bright_black", "bright_red", "bright_green", "bright_yellow",
        "bright_blue", "bright_magenta", "bright_cyan", "bright_white",
    )
    style.update({f"terminal.ansi.{name}": ansi[f"color{index}"] for index, name in enumerate(ansi_names)})
    style["syntax"] = {
        "attribute": {"color": c["teal"]},
        "boolean": {"color": c["mauve"]},
        "comment": {"color": c["muted"], "font_style": "italic"},
        "constant": {"color": c["warning"]},
        "constructor": {"color": c["success"]},
        "function": {"color": c["accent"]},
        "keyword": {"color": c["danger"]},
        "number": {"color": c["warning"]},
        "operator": {"color": c["teal"]},
        "property": {"color": c["teal"]},
        "punctuation": {"color": c["muted"]},
        "punctuation.bracket": {"color": c["foreground"]},
        "punctuation.delimiter": {"color": c["muted"]},
        "string": {"color": c["info"]},
        "string.escape": {"color": c["warning"]},
        "string.regex": {"color": c["teal"]},
        "tag": {"color": c["success"]},
        "text.literal": {"color": c["info"]},
        "type": {"color": c["success"]},
        "variable": {"color": c["foreground"]},
        "variable.special": {"color": c["mauve"]},
    }
    return canonical_json({
        "$schema": ZED_THEME_SCHEMA,
        "name": ZED_THEME_FAMILY_NAME,
        "author": ZED_THEME_AUTHOR,
        "themes": [{
            "name": zed_theme_label(theme),
            "appearance": theme["variant"],
            "style": style,
        }],
    })


def render_code_extension(theme: dict[str, Any]) -> dict[str, str]:
    colour_theme = _editor_theme(theme)
    return {
        "code/package.json": _editor_package(theme),
        "code/themes/blox-generated-color-theme.json": canonical_json(colour_theme),
        "code/settings.json": render_editor(theme),
    }


def render_cursor_extension(theme: dict[str, Any]) -> dict[str, str]:
    """Render Cursor's package using the same resolved theme JSON as Code."""
    colour_theme = canonical_json(_editor_theme(theme))
    return {
        "cursor-editor/package.json": _editor_package(theme),
        "cursor-editor/themes/blox-generated-color-theme.json": colour_theme,
        "cursor-editor/settings.json": render_cursor_editor(theme),
    }


def render_obsidian(theme: dict[str, Any]) -> dict[str, str]:
    """Render a self-contained native Obsidian theme package.

    Obsidian applies the same package to dark and light app classes. Blox
    therefore emits the selected theme variant for both classes and lets the
    source theme, rather than Obsidian's base theme, own the full palette.
    """
    c = target_colours(theme, "obsidian")
    radius = int(derive_shape(theme)["gtk_radius"])
    radius_s = 0 if radius == 0 else max(2, radius - 4)
    radius_l = 0 if radius == 0 else radius + 4

    def rgb(value: str) -> str:
        return ", ".join(str(int(value[index:index + 2], 16)) for index in (1, 3, 5))

    variables = {
        "background-primary": c["background"],
        "background-primary-alt": c["surface"],
        "background-secondary": c["surface"],
        "background-secondary-alt": c["surface_alt"],
        "background-modifier-border": c["border"],
        "background-modifier-border-hover": c["accent"],
        "background-modifier-hover": c["surface_alt"],
        "background-modifier-form-field": c["background"],
        "background-modifier-active-hover": c["surface_alt"],
        "divider-color": c["border"],
        "text-normal": c["foreground"],
        "text-muted": c["muted"],
        "text-faint": c["muted"],
        "text-accent": c["accent"],
        "text-accent-hover": c["info"],
        "text-on-accent": c["selection_foreground"],
        "interactive-normal": c["surface"],
        "interactive-hover": c["surface_alt"],
        "interactive-accent": c["accent"],
        "interactive-accent-hover": c["info"],
        "code-background": c["surface"],
        "blockquote-border": c["accent"],
        "tag-background": c["surface"],
        "tag-color": c["accent"],
        "titlebar-background": c["background"],
        "titlebar-background-focused": c["background"],
        "ribbon-background": c["surface"],
        "status-bar-background": c["surface"],
        "nav-item-background-active": c["surface_alt"],
        "nav-item-background-hover": c["surface"],
        "nav-item-color": c["muted"],
        "nav-item-color-active": c["foreground"],
        "nav-item-color-hover": c["foreground"],
        "tab-text-color-focused-active": c["foreground"],
        "icon-color": c["muted"],
        "icon-color-active": c["accent"],
        "icon-color-hover": c["foreground"],
        "scrollbar-thumb-bg": c["border"],
        "scrollbar-active-thumb-bg": c["accent"],
        "scrollbar-bg": c["background"],
        "color-accent": c["accent"],
        "color-red": c["danger"],
        "color-orange": c["warning"],
        "color-yellow": c["warning"],
        "color-green": c["success"],
        "color-cyan": c["teal"],
        "color-blue": c["info"],
        "color-purple": c["mauve"],
        "font-interface": theme["fonts"]["ui"],
        "font-text": theme["fonts"]["ui"],
        "font-monospace": theme["fonts"]["mono"],
        "radius-s": f"{radius_s}px",
        "radius-m": f"{radius}px",
        "radius-l": f"{radius_l}px",
        "input-radius": f"{radius}px",
        "button-radius": f"{radius}px",
        "checkbox-radius": f"{radius_s}px",
        "tab-radius": f"{radius}px",
        "tab-radius-active": f"{radius}px",
        "modal-radius": f"{radius_l}px",
        "prompt-radius": f"{radius_l}px",
        "callout-radius": f"{radius}px",
        "code-radius": f"{radius}px",
        "embed-border-radius": f"{radius}px",
        "img-radius": f"{radius}px",
        "color-accent-rgb": rgb(c["accent"]),
        "color-red-rgb": rgb(c["danger"]),
        "color-green-rgb": rgb(c["success"]),
        "color-blue-rgb": rgb(c["info"]),
    }
    variable_text = "\n".join(f"  --{name}: {value};" for name, value in variables.items())
    css = f"""/* Generated by themectl for {theme["name"]} ({theme["variant"]}). */
.theme-dark, .theme-light {{
{variable_text}
  color-scheme: {"light" if theme["variant"] == "light" else "dark"};
}}

body, .app-container, .workspace, .workspace-tab-container {{
  background: var(--background-primary);
  color: var(--text-normal);
  font-family: var(--font-text);
}}

.workspace-tab-header-container,
.workspace-tab-header-inner,
.nav-file-title,
.nav-folder-title,
.menu,
.modal,
.prompt,
.callout,
.markdown-rendered pre,
.markdown-rendered table,
.search-result-container,
.suggestion-container {{
  border-radius: var(--radius-m);
}}

.workspace-tab-header.is-active {{
  background: var(--background-secondary);
  border-radius: var(--tab-radius-active) var(--tab-radius-active) 0 0;
}}

.markdown-rendered a,
.cm-s-obsidian .cm-link,
.cm-s-obsidian .cm-hmd-internal-link {{
  color: var(--text-accent);
}}

.markdown-rendered img {{
  border-radius: var(--img-radius);
}}
"""
    manifest = canonical_json({
        "name": OBSIDIAN_THEME_NAME,
        "version": OBSIDIAN_THEME_VERSION,
        "minAppVersion": OBSIDIAN_THEME_MIN_APP_VERSION,
        "author": OBSIDIAN_THEME_AUTHOR,
        "authorUrl": "https://obsidian.md",
    })
    return {
        "obsidian/manifest.json": manifest,
        "obsidian/theme.css": css,
    }


def render_powerlevel10k(theme: dict[str, Any]) -> str:
    c = theme["colours"]
    return """# Generated by themectl; edit the source theme, not this file.
typeset -g POWERLEVEL9K_BACKGROUND=%s
typeset -g POWERLEVEL9K_FOREGROUND=%s
typeset -g POWERLEVEL9K_OS_ICON_BACKGROUND=%s
typeset -g POWERLEVEL9K_DIR_BACKGROUND=%s
typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=%s
typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=%s
typeset -g POWERLEVEL9K_STATUS_ERROR_BACKGROUND=%s
""" % (c["surface"], c["foreground"], c["mauve"], c["accent"], c["success"], c["warning"], c["danger"])


def render_widgets(theme: dict[str, Any]) -> str:
    widgets = theme.get("widgets", {})
    profile = widgets.get("profile") or load_defaults_document()["widgets"]["profile"]
    return canonical_json({"schema_version": 1, "profile": profile, **default_widget_profile(profile), "items": widgets.get("items", [])})


def render_theme(theme: dict[str, Any], source_path: Path | None = None) -> tuple[dict[str, str], list[str]]:
    ansi = derive_ansi(theme)
    files: dict[str, str] = {}
    targets = theme["targets"]
    if targets["quickshell"]:
        files["quickshell/theme.json"] = render_quickshell(theme, ansi)
    if targets["kitty"]:
        files["kitty/theme.conf"] = render_kitty(theme, ansi)
    if targets["wallpaper"]:
        files["hypr/wallpaper.json"] = render_wallpaper(theme, source_path)
    if targets["gtk"]:
        files.update(render_gtk(theme))
    if targets.get("helium", False):
        from .chromium import render_helium_theme

        files["helium/manifest.json"] = render_helium_theme(theme)
    if targets.get("chromium", False):
        from .chromium import render_chromium_theme

        files["chromium/manifest.json"] = render_chromium_theme(theme)
    if targets["cursor"]:
        from .cursor import cursor_metadata

        files["cursor/metadata.json"] = canonical_json(cursor_metadata(theme))
    if targets["hyprland"]:
        files["hyprland/theme.lua"] = render_hyprland(theme)
        files["hyprland/hyprtoolkit.conf"] = render_hyprtoolkit(theme)
    if targets["hyprlock"]:
        files["hyprlock/theme.conf"] = render_hyprlock(theme)
    if targets["btop"]:
        files["btop/theme.theme"] = render_btop(theme)
    if targets["micro"]:
        files["micro/blox-theme.micro"] = render_micro(theme)
    if targets["glow"]:
        files["glow/style.json"] = render_glow(theme)
    if targets["code"]:
        files.update(render_code_extension(theme))
    if targets["cursor_editor"]:
        files.update(render_cursor_extension(theme))
    if targets.get("t3code", False):
        files["t3code/theme.json"] = render_t3code(theme)
    if targets.get("zed", False):
        files["zed/themes/blox-generated.json"] = render_zed(theme)
    if targets["stylus"]:
        from .stylus import render_stylus, render_stylus_manifest

        files["stylus/blox-system.user.css"] = render_stylus(theme)
        files["stylus/manifest.json"] = render_stylus_manifest(theme)
    if targets.get("obsidian", False):
        files.update(render_obsidian(theme))
    if targets["powerlevel10k"]:
        files["powerlevel10k/theme.zsh"] = render_powerlevel10k(theme)
    if targets["widgets"]:
        files["widgets/profile.json"] = render_widgets(theme)
    warnings = [message for target, message in {**DEFERRED_TARGETS, **TARGET_LIMITATIONS}.items() if targets.get(target, False)]
    return dict(sorted(files.items())), warnings


def render_manifest(theme_path_value: Path, theme: dict[str, Any], files: dict[str, str]) -> dict[str, Any]:
    source = canonical_json(theme)
    return {
        "schema_version": 1,
        "renderer_version": RENDERER_VERSION,
        "source": str(theme_path_value.resolve()),
        "source_sha256": sha256_text(source),
        "theme_id": theme["id"],
        "files": {name: sha256_text(content) for name, content in files.items()},
        "derived": {"ansi": derive_ansi(theme)},
    }


def write_render(output: Path, files: dict[str, str], manifest: dict[str, Any]) -> None:
    resolved_output = output.expanduser().resolve()
    resolved_state = state_dir().resolve()
    if resolved_output == resolved_state or resolved_state in resolved_output.parents:
        raise ValueError("render output must not be inside the live theme state directory")
    if resolved_output.exists() and any(resolved_output.iterdir()):
        raise ValueError(f"render output is not empty: {resolved_output}")
    output = resolved_output
    output.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    (output / "manifest.json").write_text(canonical_json(manifest), encoding="utf-8")


def rendered_diff(files: dict[str, str]) -> list[dict[str, Any]]:
    current = state_dir() / "current"
    changes = []
    for name, content in files.items():
        live = current / name
        old = live.read_text(encoding="utf-8") if live.is_file() else None
        changes.append({"path": name, "change": "add" if old is None else "unchanged" if old == content else "modify", "old_sha256": sha256_text(old) if old is not None else None, "new_sha256": sha256_text(content)})
    return changes
