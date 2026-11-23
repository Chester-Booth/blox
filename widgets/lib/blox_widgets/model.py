"""The profile contract, shared by drafts, storage and portable exports."""

from __future__ import annotations

import copy
import json
import math
from pathlib import Path
import re
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schema" / "profile.schema.json"
CATALOGUE_PATH = ROOT / "catalogue.json"


class ValidationError(ValueError):
    """A document does not satisfy the fresh profile contract."""


def _fail(path: str, message: str) -> None:
    raise ValidationError(f"{path}: {message}")


def _is_type(value: Any, name: str) -> bool:
    if name == "object":
        return isinstance(value, dict) and all(isinstance(key, str) for key in value)
    if name == "array":
        return isinstance(value, list)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "null":
        return value is None
    return False


def _matches(value: Any, rule: dict, root: dict, path: str) -> bool:
    try:
        _validate(value, rule, root, path)
        return True
    except ValidationError:
        return False


def _validate(value: Any, rule: dict, root: dict, path: str) -> None:
    """Evaluate the small JSON Schema vocabulary used by our checked-in schema."""
    if "$ref" in rule:
        target = root
        for part in rule["$ref"].removeprefix("#/").split("/"):
            target = target[part.replace("~1", "/").replace("~0", "~")]
        _validate(value, target, root, path)
    if "type" in rule:
        types = rule["type"] if isinstance(rule["type"], list) else [rule["type"]]
        if not any(_is_type(value, name) for name in types):
            _fail(path, f"expected {' or '.join(types)}")
    if "const" in rule and (type(value) is not type(rule["const"]) or value != rule["const"]):
        _fail(path, f"expected {rule['const']!r}")
    if "enum" in rule and not any(type(value) is type(item) and value == item for item in rule["enum"]):
        _fail(path, f"expected one of {rule['enum']!r}")
    for branch in rule.get("allOf", []):
        _validate(value, branch, root, path)
    if "anyOf" in rule and not any(_matches(value, branch, root, path) for branch in rule["anyOf"]):
        _fail(path, "does not match an allowed value")
    if "oneOf" in rule:
        branches = rule["oneOf"]
        # A discriminator gives useful errors for a known kind instead of a generic union error.
        if isinstance(value, dict) and "kind" in value:
            selected = [branch for branch in branches if branch.get("properties", {}).get("kind", {}).get("const") == value["kind"]]
            if len(selected) == 1:
                _validate(value, selected[0], root, path)
            elif sum(_matches(value, branch, root, path) for branch in branches) != 1:
                _fail(path, "unknown widget kind or invalid widget")
        elif sum(_matches(value, branch, root, path) for branch in branches) != 1:
            _fail(path, "must match exactly one allowed value")
    if "if" in rule and _matches(value, rule["if"], root, path):
        _validate(value, rule.get("then", {}), root, path)
    if isinstance(value, dict):
        for key in rule.get("required", []):
            if key not in value:
                _fail(path, f"missing {key!r}")
        if len(value) > rule.get("maxProperties", math.inf):
            _fail(path, "too many properties")
        properties = rule.get("properties", {})
        for key, item in value.items():
            if "propertyNames" in rule:
                _validate(key, rule["propertyNames"], root, path)
            if key in properties:
                _validate(item, properties[key], root, f"{path}.{key}")
            elif rule.get("additionalProperties") is False:
                _fail(path, f"unknown field {key!r}")
            elif isinstance(rule.get("additionalProperties"), dict):
                _validate(item, rule["additionalProperties"], root, f"{path}.{key}")
        if "x-blox-terminalBudget" in rule or "x-blox-commandBudget" in rule:
            budget = rule.get("x-blox-terminalBudget", rule.get("x-blox-commandBudget"))
            label = "terminal" if "x-blox-terminalBudget" in rule else "command"
            if "maxCells" in budget and value["columns"] * value["rows"] > budget["maxCells"]:
                _fail(path, f"terminal grid exceeds {budget['maxCells']} cells")
            records = [value] + [action for action in value.get("actions", {}).values() if action is not None]
            argv_bytes = sum(len(argument.encode("utf-8")) for record in records for argument in record["command"])
            environment_bytes = sum(len(key.encode("utf-8")) + len(item.encode("utf-8"))
                                    for record in records for key, item in record.get("environment", {}).items())
            if argv_bytes + environment_bytes > budget["maxArgvEnvironmentUtf8Bytes"]:
                _fail(path, f"{label} command and environment exceed the combined UTF-8 byte budget")
            encoded = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("ascii")
            if len(encoded) > budget["maxEncodedJsonBytes"]:
                _fail(path, f"{label} settings exceed the encoded JSON byte budget")
    if isinstance(value, list):
        if len(value) < rule.get("minItems", 0) or len(value) > rule.get("maxItems", math.inf):
            _fail(path, "array length outside allowed bounds")
        if "items" in rule:
            for index, item in enumerate(value):
                _validate(item, rule["items"], root, f"{path}[{index}]")
        for index, prefix in enumerate(rule.get("prefixItems", [])):
            if index < len(value):
                _validate(value[index], prefix, root, f"{path}[{index}]")
        if rule.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True, ensure_ascii=True, allow_nan=False) for item in value]
            if len(set(encoded)) != len(encoded):
                _fail(path, "duplicate array entries")
        if "contains" in rule and not any(_matches(item, rule["contains"], root, path) for item in value):
            _fail(path, "required layout is absent")
        if rule.get("x-blox-orderedRange") and value[0] > value[1]:
            _fail(path, "range start must not exceed range end")
        unique_by = rule.get("x-blox-uniqueBy")
        if unique_by:
            identifiers = [item[unique_by] for item in value]
            if len(set(identifiers)) != len(identifiers):
                _fail(path, f"duplicate {unique_by}")
    if isinstance(value, str):
        if len(value) < rule.get("minLength", 0) or len(value) > rule.get("maxLength", math.inf):
            _fail(path, "string length outside allowed bounds")
        if "pattern" in rule and re.search(rule["pattern"], value) is None:
            _fail(path, "string does not match the required format")
        if "x-blox-maxUtf8Bytes" in rule:
            try:
                size = len(value.encode("utf-8"))
            except UnicodeEncodeError as error:
                raise ValidationError(f"{path}: expected valid Unicode text") from error
            if size > rule["x-blox-maxUtf8Bytes"]:
                _fail(path, "string exceeds the UTF-8 byte budget")
        if rule.get("format") == "blox-timezone" and value != "local":
            try:
                ZoneInfo(value)
            except (ZoneInfoNotFoundError, ValueError) as error:
                raise ValidationError(f"{path}: unknown timezone {value!r}") from error
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            _fail(path, "number must be finite")
        if value < rule.get("minimum", -math.inf) or value > rule.get("maximum", math.inf):
            _fail(path, "number outside allowed bounds")


def _normalise_numbers(value: Any) -> Any:
    # JSON Schema treats 1 and 1.0 as the same integer. Canonicalise before validation.
    if isinstance(value, dict):
        return {key: _normalise_numbers(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_normalise_numbers(item) for item in value]
    if isinstance(value, float) and math.isfinite(value) and value.is_integer():
        return int(value)
    return value


def validate_profile(document: Any) -> dict:
    """Validate without mutation, returning canonical numbers and appearance defaults in an independent copy."""
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    try:
        document = _normalise_numbers(document)
        _validate(document, schema, schema, "profile")
    except (RecursionError, OverflowError) as error:
        raise ValidationError("profile: document exceeds nesting or number bounds") from error
    # Appearance is independent of provider settings and does not invalidate older profiles.
    for widget in document["widgets"]:
        widget["appearance"].setdefault("presentation", "open")
    return copy.deepcopy(document)


def validate_settings(kind: str, settings: Any) -> dict:
    """Validate complete settings, including explicit terminal restartPolicy, without filling fields."""
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    rule = schema["$defs"].get(kind + "Settings") if isinstance(kind, str) else None
    if rule is None:
        raise ValidationError(f"unknown widget kind {kind!r}")
    try:
        settings = _normalise_numbers(settings)
        _validate(settings, rule, schema, f"{kind}.settings")
    except (RecursionError, OverflowError) as error:
        raise ValidationError(f"{kind}.settings: configuration exceeds nesting or number bounds") from error
    return copy.deepcopy(settings)


def default_profile() -> dict:
    """A new profile has no active widgets or implicit external work."""
    return {"schemaVersion": 1, "widgets": []}


def catalogue() -> dict:
    return json.loads(CATALOGUE_PATH.read_text(encoding="utf-8"))


def default_widget(kind: str, identifier: str, settings: dict | None = None) -> dict:
    """Build a complete item; weather, commands, terminals and QML require explicit configuration."""
    entries = {entry["kind"]: entry for entry in catalogue()["widgets"]}
    if kind not in entries:
        raise ValidationError(f"unknown widget kind {kind!r}")
    entry = entries[kind]
    supplied = settings if settings is not None else {}
    if not isinstance(supplied, dict):
        raise ValidationError("settings: expected object")
    missing = [key for key in entry["requiresConfiguration"] if key not in supplied]
    if missing:
        raise ValidationError(f"{kind}: explicit configuration required for {', '.join(missing)}")
    widget = {
        "id": identifier,
        "kind": kind,
        "name": entry["name"],
        "enabled": True,
        "placement": {"anchor": "top-left", "x": 24, "y": 24, "width": entry["width"], "height": entry["height"]},
        "workspaces": {"mode": "all", "ids": [], "ranges": []},
        "visibility": "always",
        "appearance": {"backgroundOpacity": 0.8, "scrollbars": "auto", "presentation": "open"},
        "fullscreen": {"enabled": False, "mode": "resize" if kind == "terminal" else "native"},
        "settings": {**copy.deepcopy(entry["defaultSettings"]), **copy.deepcopy(supplied)},
    }
    if kind == "command":
        widget["placement"]["sizing"] = "content"
    if kind == "qml" and isinstance(widget["settings"]["layouts"], list) and widget["settings"]["layouts"]:
        widget["fullscreen"]["mode"] = widget["settings"]["layouts"][0]
    return validate_profile({"schemaVersion": 1, "widgets": [widget]})["widgets"][0]


def parse_profile(text: str) -> dict:
    """Reject duplicate JSON keys and non-finite numbers before schema validation."""
    if not isinstance(text, str) or len(text.encode("utf-8")) > 4 * 1024 * 1024:
        raise ValidationError("profile: JSON document exceeds 4 MiB")

    def pairs(items: list) -> dict:
        result = {}
        for key, value in items:
            if key in result:
                raise ValidationError(f"profile: duplicate JSON key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> None:
        raise ValidationError(f"profile: invalid JSON number {value}")

    try:
        document = json.loads(text, object_pairs_hook=pairs, parse_constant=reject_constant)
    except (json.JSONDecodeError, RecursionError) as error:
        raise ValidationError(f"profile: invalid JSON: {error}") from error
    return validate_profile(document)
