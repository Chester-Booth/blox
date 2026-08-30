"""Built-in truth contract (Phase 3 steps 01-02).

Classifies schema leaves into authored options, explicit absence states and
derived provenance, then enforces the release-plan promise permanently: no
built-in omits an authored option, and the defaults document satisfies its own
schema.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import apply_theme_defaults, defaults_schema_errors  # noqa: E402

SCHEMA = json.loads((THEMES / "schema" / "theme.schema.json").read_text(encoding="utf-8"))
DEFAULTS_DOCUMENT = json.loads((THEMES / "defaults" / "v1.json").read_text(encoding="utf-8"))
CANONICAL_THEME = json.loads((THEMES / "builtin" / "catppuccin-frappe.json").read_text(encoding="utf-8"))

# Provenance stamped by generators.py onto generated themes only; hand
# written built-ins must not fake it.
DERIVED_PREFIXES = ("generator.",)
OPTIONAL_STATE_LEAVES = {
    "shape.window_gap",
    "shell.bar.separate_groups",
    "shell.bar.border",
    "shell.bar.edge_inset",
    "shell.bar.radius_automatic",
    "shell.bar.radius_scale",
    "shell.bar.density_automatic",
    "shell.bar.density_scale",
    "targets.t3code",
    "stylus.style_set",
}


def _resolve(node: dict) -> dict:
    ref = node.get("$ref")
    if isinstance(ref, str) and ref.startswith("#/$defs/"):
        return SCHEMA["$defs"][ref.split("/")[-1]]
    return node


def _leaves(node: dict, path: str = "") -> dict[str, dict]:
    found: dict[str, dict] = {}
    for key, value in node.get("properties", {}).items():
        child = f"{path}.{key}" if path else key
        resolved = _resolve(value)
        if not isinstance(resolved, dict):
            found[child] = value
        elif "required" in resolved and "properties" in resolved:
            # A record def: fixed-shape object whose fields are options.
            found.update(_leaves(resolved, child))
        elif "properties" in value:
            # Inline container: recurse field by field.
            found.update(_leaves(value, child))
        else:
            # A sparse optional map (semanticOverride and friends) stays a
            # single leaf; stating it at all is the option.
            found[child] = value
    return found


ALL_LEAVES = _leaves(SCHEMA)
AUTHORED_LEAVES = {
    path: value
    for path, value in ALL_LEAVES.items()
    if not path.startswith(DERIVED_PREFIXES) and path not in OPTIONAL_STATE_LEAVES
}


class BuiltinTruthTests(unittest.TestCase):
    def documents(self) -> list[tuple[str, dict]]:
        return [
            (path.stem, json.loads(path.read_text(encoding="utf-8")))
            for path in sorted(THEMES.glob("builtin/*.json"))
        ]

    def test_builtins_set_every_authored_option(self) -> None:
        report = {name: gaps for name, doc in self.documents() if (gaps := _missing_authored(doc))}
        self.assertEqual(report, {}, "built-ins omit authored schema options")

    def test_derived_leaves_are_exactly_the_generator_block(self) -> None:
        derived = sorted(p for p in ALL_LEAVES if p.startswith(DERIVED_PREFIXES))
        self.assertEqual(
            derived,
            [
                "generator.backend",
                "generator.mapping_version",
                "generator.options.contrast",
                "generator.options.mode",
                "generator.options.saturation",
                "generator.options.scheme",
                "generator.options.source_colour_index",
                "generator.version",
                "generator.wallpaper_sha256",
            ],
        )

    def test_optional_absence_has_one_named_meaning(self) -> None:
        self.assertEqual(
            OPTIONAL_STATE_LEAVES,
            {
                "shape.window_gap",
                "shell.bar.separate_groups",
                "shell.bar.border",
                "shell.bar.edge_inset",
                "shell.bar.radius_automatic",
                "shell.bar.radius_scale",
                "shell.bar.density_automatic",
                "shell.bar.density_scale",
                "targets.t3code",
                "stylus.style_set",
            },
        )
        for name, document in self.documents():
            with self.subTest(theme=name):
                self.assertNotIn("window_gap", document["shape"])

    def test_defaults_document_matches_its_own_schema(self) -> None:
        self.assertEqual(defaults_schema_errors(DEFAULTS_DOCUMENT), [])

    def test_defaults_match_the_canonical_frappe_theme(self) -> None:
        defaults = DEFAULTS_DOCUMENT["theme"]
        canonical = CANONICAL_THEME
        colour_roles = {
            "background": "background",
            "surface": "surface",
            "surface_alt": "surface_alt",
            "foreground": "foreground",
            "muted": "muted",
            "red": "danger",
            "green": "success",
            "yellow": "warning",
            "accent": "accent",
            "blue": "info",
            "mauve": "mauve",
            "teal": "teal",
            "selection_background": "selection_background",
            "selection_foreground": "selection_foreground",
            "border": "border",
        }

        self.assertEqual(defaults["id"], canonical["id"])
        self.assertEqual(defaults["variant"], canonical["variant"])
        self.assertEqual(
            defaults["colours"],
            {default: canonical["colours"][source] for default, source in colour_roles.items()},
        )
        self.assertEqual(defaults["fonts"], canonical["fonts"])
        self.assertEqual(defaults["shape"], canonical["shape"])
        self.assertEqual(defaults["shell"]["bar"]["position"], canonical["shell"]["bar"]["position"])
        self.assertFalse(defaults["shell"]["bar"]["separate_groups"])
        self.assertFalse(defaults["shell"]["bar"]["border"])
        self.assertEqual(0, defaults["shell"]["bar"]["edge_inset"])
        self.assertEqual(defaults["shell"]["bar"]["reset_items"], canonical["shell"]["bar"]["items"])
        self.assertEqual(defaults["shell"]["osd"], canonical["shell"]["osd"])
        self.assertEqual(defaults["shell"]["notifications"], canonical["shell"]["notifications"])
        self.assertEqual(defaults["wallpaper"], canonical["wallpaper"])
        self.assertEqual(defaults["terminal"], canonical["terminal"])
        self.assertEqual(DEFAULTS_DOCUMENT["widgets"]["profile"], canonical["widgets"]["profile"])

    def test_sparse_theme_uses_the_canonical_fallback_values(self) -> None:
        source = json.loads((THEMES.parent / "tests" / "qml" / "fixtures" / "sparse-theme.json").read_text(encoding="utf-8"))
        expected = json.loads((THEMES.parent / "tests" / "qml" / "fixtures" / "resolved-sparse-theme.json").read_text(encoding="utf-8"))
        resolved = apply_theme_defaults(source)
        defaults = DEFAULTS_DOCUMENT["theme"]

        self.assertEqual(resolved, expected)
        self.assertEqual(resolved["id"], "sparse")
        self.assertEqual(resolved["variant"], defaults["variant"])
        self.assertEqual(resolved["fonts"], defaults["fonts"])
        self.assertEqual(resolved["shape"], defaults["shape"])
        self.assertEqual(resolved["wallpaper"], defaults["wallpaper"])
        self.assertEqual(resolved["terminal"], defaults["terminal"])
        self.assertEqual(resolved["widgets"]["profile"], DEFAULTS_DOCUMENT["widgets"]["profile"])


class ConfiguredTargetsContractTests(unittest.TestCase):
    def test_default_selection_skips_disabled_targets(self) -> None:
        from blox_theme.runtime import TARGET_NAMES, configured_targets

        theme = {"targets": {name: False for name in TARGET_NAMES}}
        theme["targets"]["quickshell"] = True
        theme["targets"]["gtk"] = True
        self.assertEqual(configured_targets(theme), ("quickshell", "gtk"))

    def test_explicit_request_for_disabled_target_is_refused(self) -> None:
        from blox_theme.runtime import TARGET_NAMES, RuntimeFailure, configured_targets

        theme = {"targets": {name: False for name in TARGET_NAMES}}
        with self.assertRaises(RuntimeFailure) as caught:
            configured_targets(theme, "glow")
        self.assertIn("disabled by theme", str(caught.exception))


def _missing_authored(document: dict) -> list[str]:
    gaps: list[str] = []
    for path in AUTHORED_LEAVES:
        node: object = document
        for part in path.split("."):
            if not isinstance(node, dict) or part not in node:
                gaps.append(path)
                break
            node = node[part]
    return sorted(gaps)


if __name__ == "__main__":
    unittest.main()
