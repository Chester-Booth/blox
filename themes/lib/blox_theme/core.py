from __future__ import annotations

import copy
import hashlib
import importlib
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
THEME_SCHEMA_VERSION = 1

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


def widget_model() -> Any:
    """Load the shared widget contract from source or the installed data root."""
    data = Path(__file__).resolve().parents[2]
    for library in (data / "widgets/lib", data.parent / "widgets/lib"):
        if (library / "blox_widgets/model.py").is_file():
            location = str(library)
            sys.path.insert(0, location)
            try:
                return importlib.import_module("blox_widgets.model")
            finally:
                sys.path.remove(location)
    raise DefaultsFailure(f"widget model is missing from the application data root: {data}")


def default_widget_profile() -> dict[str, Any]:
    return widget_model().validate_profile(load_defaults_document()["widgets"])


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


def state_home() -> Path:
    root = os.environ.get("XDG_STATE_HOME")
    return Path(root).expanduser() if root else Path.home() / ".local/state"


def state_dir() -> Path:
    """Return the single canonical root for generated theme state."""
    return state_home() / "blox" / "theme"


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
    version = theme.get("schema_version")
    if type(version) is not int:
        raise ValueError("theme schema_version must be an integer")
    if version != THEME_SCHEMA_VERSION:
        raise ValueError(
            f"theme schema version {version} is unsupported; supported version is {THEME_SCHEMA_VERSION}"
        )
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
        "widgets": copy.deepcopy(document["widgets"]),
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

    resolved = merge(fragment, theme)
    # A widget profile is a complete shared document, not a sparse theme section.
    if "widgets" in theme:
        resolved["widgets"] = copy.deepcopy(theme["widgets"])
    return resolved


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
            widgets = widget_model().validate_profile(resolved["widgets"])
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
                            for item in widgets["widgets"]
                            if item["enabled"]
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
    for subschema in schema.get("allOf", []):
        errors.extend(_basic_schema_errors(instance, subschema, root, path))
    if "anyOf" in schema and not any(
        not _basic_schema_errors(instance, branch, root, path) for branch in schema["anyOf"]
    ):
        errors.append(f"{path}: does not match any allowed form")
    if "if" in schema:
        condition_matches = not _basic_schema_errors(instance, schema["if"], root, path)
        branch = schema.get("then" if condition_matches else "else")
        if branch is not None:
            errors.extend(_basic_schema_errors(instance, branch, root, path))
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
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append(f"{path}: has too many items")
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
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: must be greater than {schema['exclusiveMinimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: must be at most {schema['maximum']}")
    return errors


def _schema_errors_with_widget_profile(document: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    """Use the shared validator for widgets, including its semantic constraints."""
    # The published schema references the widget schema by its canonical id.
    # Validate that field locally so validation never fetches a remote schema.
    schema["properties"]["widgets"] = {}
    widget_errors: list[str] = []
    if isinstance(document, dict) and "widgets" in document:
        model = widget_model()
        try:
            model.validate_profile(document["widgets"])
        except model.ValidationError as error:
            widget_errors.append(f"widgets: {error}")
    try:
        import jsonschema

        validator = jsonschema.Draft202012Validator(schema)
        errors = [f"{'.'.join(str(part) for part in error.absolute_path) or '$'}: {error.message}" for error in sorted(validator.iter_errors(document), key=lambda item: list(item.absolute_path))]
    except ImportError:
        errors = _basic_schema_errors(document, schema, schema)
    return errors + widget_errors


def schema_errors(theme: dict[str, Any]) -> list[str]:
    schema = load_json(themes_dir() / "schema/theme.schema.json")
    return _schema_errors_with_widget_profile(theme, schema)


def defaults_schema_errors(document: dict[str, Any]) -> list[str]:
    schema = load_json(themes_dir() / "schema/defaults.schema.json")
    return _schema_errors_with_widget_profile(document, schema)


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


from .render_editors import (  # noqa: E402, F401
    EDITOR_MINIMUM_VERSION,
    EDITOR_THEME_LABEL_PREFIX,
    EDITOR_THEME_PACKAGE_NAME,
    EDITOR_THEME_PUBLISHER,
    EDITOR_THEME_RELATIVE_PATH,
    EDITOR_THEME_VERSION,
    editor_colours,
    editor_modern_ui_value,
    editor_theme_label,
    editor_theme_setting_value,
    render_code_extension,
    render_cursor_editor,
    render_cursor_extension,
    render_editor,
    render_obsidian,
    render_t3code,
    render_zed,
    zed_theme_label,
)
from .render_targets import (  # noqa: E402, F401
    render_btop,
    render_glow,
    render_gtk,
    render_gtk3,
    render_gtk4,
    render_gtk_settings,
    render_hyprland,
    render_hyprlock,
    render_hyprtoolkit,
    render_kitty,
    render_manifest,
    render_micro,
    render_powerlevel10k,
    render_quickshell,
    render_theme,
    render_wallpaper,
    render_widgets,
    rendered_diff,
    write_render,
)
