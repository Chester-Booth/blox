"""Built-in truth contract (Phase 3 steps 01-02).

Classifies schema leaves into authored options and derived provenance,
then enforces the release-plan promise permanently: no built-in omits an
authored option, and the defaults document satisfies its own schema.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import defaults_schema_errors  # noqa: E402

SCHEMA = json.loads((THEMES / "schema" / "theme.schema.json").read_text(encoding="utf-8"))
DEFAULTS_DOCUMENT = json.loads((THEMES / "defaults" / "v1.json").read_text(encoding="utf-8"))

# Provenance stamped by generators.py onto generated themes only; hand
# written built-ins must not fake it.
DERIVED_PREFIXES = ("generator.",)


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
AUTHORED_LEAVES = {p: v for p, v in ALL_LEAVES.items() if not p.startswith(DERIVED_PREFIXES)}


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

    def test_defaults_document_matches_its_own_schema(self) -> None:
        self.assertEqual(defaults_schema_errors(DEFAULTS_DOCUMENT), [])


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
