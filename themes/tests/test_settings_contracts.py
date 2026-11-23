"""Focused checks for the versioned Settings and theme field contracts."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

try:
    import jsonschema
except ModuleNotFoundError:
    jsonschema = None

from themes.lib.blox_theme.core import _basic_schema_errors, _schema_errors_with_widget_profile


ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "shell/scripts/contracts"
THEMES = ROOT / "themes"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_ref(node: dict, schema: dict) -> dict:
    ref = node.get("$ref")
    if not ref:
        return node
    current = schema
    for part in ref.removeprefix("#/").split("/"):
        current = current[part]
    return current


def validate(instance: dict, schema: dict) -> None:
    if schema.get('properties', {}).get('widgets', {}).get('$ref') == 'https://blox.local/widgets/profile.schema.json':
        errors = _schema_errors_with_widget_profile(instance, json.loads(json.dumps(schema)))
        if errors:
            raise AssertionError('; '.join(errors))
        return
    if jsonschema is not None:
        try:
            jsonschema.validate(instance, schema)
        except jsonschema.ValidationError as error:
            raise AssertionError(str(error)) from error
        return
    errors = _basic_schema_errors(instance, schema, schema)
    if errors:
        raise AssertionError("; ".join(errors))


def check_schema_refs(schema: dict) -> None:
    def walk(value: object) -> None:
        if isinstance(value, dict):
            if "$ref" in value:
                resolve_ref(value, schema)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(schema)


def schema_leaf_paths(schema: dict) -> set[str]:
    paths: set[str] = set()

    def walk(node: dict, path: str) -> None:
        node = resolve_ref(node, schema)
        alternatives = node.get("oneOf", node.get("anyOf"))
        if alternatives:
            for alternative in alternatives:
                walk(alternative, path)
        elif node.get("type") == "object" and "properties" in node:
            for name, child in node["properties"].items():
                walk(child, f"{path}.{name}" if path else name)
        elif node.get("type") == "array":
            walk(node.get("items", {}), path + "[*]")
        else:
            paths.add(path)

    for name, node in schema["properties"].items():
        walk(node, name)
    return paths


def resolve_legacy_path(schema: dict, path: str) -> dict:
    """Resolve dotted v1 theme paths, including refs and array item markers."""
    node = schema
    parts = path.replace("[*]", ".[array]").split(".")
    for part in parts:
        node = resolve_ref(node, schema)
        if part == "[array]":
            if node.get("type") != "array":
                raise KeyError(f"{path}: expected an array")
            node = node["items"]
        elif "properties" in node and part in node["properties"]:
            node = node["properties"][part]
        elif node.get("type") == "object" and node.get("additionalProperties", True) is True:
            node = {}
        else:
            raise KeyError(f"{path}: no property {part!r}")
    return node


class SettingsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.settings_schema = read_json(CONTRACTS / "settings-v1.schema.json")
        cls.settings_defaults = read_json(CONTRACTS / "settings-defaults-v1.json")
        cls.registry_schema = read_json(CONTRACTS / "settings-fields-v1.schema.json")
        cls.registry = read_json(CONTRACTS / "settings-fields-v1.json")
        cls.manifest_schema = read_json(THEMES / "schema/components-v1.schema.json")
        cls.manifest = read_json(THEMES / "schema/components-v1.json")

    def test_new_schemas_are_valid_and_defaults_match(self) -> None:
        for schema in (self.settings_schema, self.registry_schema, self.manifest_schema):
            if jsonschema is not None:
                jsonschema.Draft202012Validator.check_schema(schema)
            else:
                check_schema_refs(schema)

        validate(self.settings_defaults, self.settings_schema)
        validate(self.registry, self.registry_schema)
        validate(self.manifest, self.manifest_schema)
        self.assertEqual(1, self.settings_defaults["schemaVersion"])
        self.assertEqual(0, self.settings_defaults["revision"])
        self.assertEqual([], self.settings_defaults["monitors"])
        self.assertEqual(
            {"returnsDefaultsFrom": "settings-defaults-v1.json", "writesFile": False},
            self.settings_schema["x-absentDocument"],
        )
        invalid = dict(self.settings_defaults, schemaVersion=2)
        with self.assertRaises(AssertionError):
            validate(invalid, self.settings_schema)

    def test_every_settings_schema_leaf_has_exactly_one_registry_owner(self) -> None:
        schema_paths = {"settings." + path for path in schema_leaf_paths(self.settings_schema)}
        registry_paths = [
            field["path"]
            for group in self.registry["fields"]
            for field in group["fields"]
        ]
        self.assertEqual(len(registry_paths), len(set(registry_paths)), "a field has more than one registry owner")
        settings_paths = {path for path in registry_paths if path.startswith("settings.")}
        self.assertEqual(schema_paths, settings_paths)

        for group in self.registry["fields"]:
            self.assertIsInstance(group["storageOwner"], str)
            self.assertTrue(group["storageOwner"])
            self.assertIsInstance(group["runtimeOwner"], str)
            self.assertTrue(group["runtimeOwner"])
            self.assertTrue(set(group["proofSourceIds"]).issubset(self.registry["proofSources"]))

    def test_full_includes_each_non_private_data_field(self) -> None:
        for group in self.registry["fields"]:
            if group["fieldClass"] not in (
                "setting", "theme-data", "theme-metadata", "document-metadata", "private-content"
            ):
                continue
            if group["sensitivity"] == "private":
                self.assertEqual("exclude", group["bundle"]["full"], group["id"])
            else:
                self.assertIn(group["bundle"]["full"], ("include", "review"), group["id"])
            self.assertIn(group["previewSupport"], (
                "component-preview", "field-preview", "none", "not-applicable"
            ))

    def test_manifest_presets_match_component_rules_and_keep_legacy_themes_readable(self) -> None:
        components = {component["id"]: component for component in self.manifest["components"]}
        self.assertEqual(len(components), len(self.manifest["components"]))
        for group in self.registry["fields"]:
            self.assertIn(group["component"], components, group["id"])

        for tier, selected in self.manifest["bundlePresets"].items():
            for component_id, component in components.items():
                self.assertEqual(component_id in selected, component["presetIncluded"][tier], component_id)
        self.assertIn("wallpaper", self.manifest["selectableComponents"])
        self.assertTrue(all(components["wallpaper"]["presetIncluded"][tier] for tier in ("minimal", "standard", "full")))
        self.assertTrue(self.manifest["compatibility"]["readExistingThemeV1"])
        self.assertFalse(self.manifest["compatibility"]["rewriteExistingThemeFiles"])

        legacy_schema = read_json(THEMES / "schema/theme.schema.json")
        defaults = read_json(THEMES / "defaults/v1.json")
        for group in self.registry["fields"]:
            for field in group["fields"]:
                value = field["legacyReadPath"]
                if value is None:
                    continue
                source, path = value.split(":", 1)
                path = path.split(" (", 1)[0]
                if source == "theme-v1":
                    resolve_legacy_path(legacy_schema, path)
                elif source == "theme-defaults-v1":
                    path = path.replace("{preset}", defaults["widgets"]["profile"])
                    document = defaults
                    for part in path.split("."):
                        document = document[part]
                else:
                    self.fail(f"unknown legacy source: {source}")

        for path in sorted((THEMES / "builtin").glob("*.json")):
            with self.subTest(theme=path.name):
                validate(read_json(path), legacy_schema)

    def test_target_apply_mode_is_resolved_runtime_metadata_not_a_setting(self) -> None:
        mode = next(item for item in self.registry["derivedFields"] if item["path"] == "settings.targets[id].mode")
        self.assertFalse(mode["persisted"])
        self.assertEqual("resolved", mode["status"])
        self.assertIn("not a user preference", mode["resolution"])
        self.assertNotIn("settings.targets.gtk.mode", {field["path"] for group in self.registry["fields"] for field in group["fields"]})


if __name__ == "__main__":
    unittest.main()
