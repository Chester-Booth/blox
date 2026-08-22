"""Built-in truth baseline (Phase 3 step 01).

Classifies schema leaves into authored options and derived provenance,
then pins two contracts the release plan promises: no built-in omits an
authored option, and the defaults document owns only paths the schema
declares. The expectedFailure tests record today's red state; step 02
fills the gaps and removes the markers.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

SCHEMA = json.loads((THEMES / "schema" / "theme.schema.json").read_text(encoding="utf-8"))

# Provenance stamped by generators.py onto generated themes only; hand
# written built-ins must not fake it.
DERIVED_PREFIXES = ("generator.",)


def _leaves(node: dict, path: str = "") -> dict[str, dict]:
    found: dict[str, dict] = {}
    for key, value in node.get("properties", {}).items():
        child = f"{path}.{key}" if path else key
        if isinstance(value, dict) and "properties" in value:
            found.update(_leaves(value, child))
        else:
            found[child] = value
    return found


def _containers(node: dict, path: str = "", into: set[str] | None = None) -> set[str]:
    into = set() if into is None else into
    for key, value in node.get("properties", {}).items():
        child = f"{path}.{key}" if path else key
        if isinstance(value, dict) and "properties" in value:
            into.add(child)
            _containers(value, child, into)
    return into


ALL_LEAVES = _leaves(SCHEMA)
CONTAINERS = _containers(SCHEMA)
AUTHORED_LEAVES = {p: v for p, v in ALL_LEAVES.items() if not p.startswith(DERIVED_PREFIXES)}

# Recorded on 22 August 2026 by the step 01 census. Step 02 empties this
# table; changing it anywhere else must be a conscious decision.
BASELINE_GAPS = {
    name: ["overrides.gtk", "overrides.hyprlock"] + (["widgets.items"] if name not in {"dracula", "kanagawa", "tokyo-night"} else [])
    for name in (
        "catppuccin-frappe", "catppuccin-latte", "catppuccin-macchiato", "catppuccin-mocha",
        "dracula", "gruvbox-dark", "gruvbox-light", "kanagawa",
        "nord", "solarized-dark", "solarized-light", "tokyo-night",
    )
}

# Defaults-document subtrees outside the schema contract, recorded by the
# same audit. Step 02 either enumerates them in the schema or trims them.
EXPECTED_DEFAULTS_VIOLATIONS = {
    "colours.blue", "colours.green", "colours.red", "colours.yellow",
    "shell.bar.reset_items",
    "shell.notifications.position", "shell.notifications.offset_x", "shell.notifications.offset_y",
    "shell.osd.position", "shell.osd.offset_x", "shell.osd.offset_y",
    "widgets.profiles",
}


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


def _defaults_violations(document: dict) -> list[str]:
    tree = {**document["theme"], "widgets": document.get("widgets", {})}
    offenders: list[str] = []

    def walk(node: dict, path: str = "") -> None:
        for key, value in node.items():
            child = f"{path}.{key}" if path else key
            if child in ("schema_version", "defaults_version"):
                continue
            if child not in ALL_LEAVES and child not in CONTAINERS:
                offenders.append(child)
            elif isinstance(value, dict):
                walk(value, child)

    walk(tree)
    return sorted(p for p in offenders if "." not in p or p.rsplit(".", 1)[0] not in offenders)


class BuiltinTruthTests(unittest.TestCase):
    def documents(self) -> list[tuple[str, dict]]:
        return [
            (path.stem, json.loads(path.read_text(encoding="utf-8")))
            for path in sorted(THEMES.glob("builtin/*.json"))
        ]

    @unittest.expectedFailure
    def test_builtins_set_every_authored_option(self) -> None:
        report = {name: _missing_authored(doc) for name, doc in self.documents()}
        offending = {name: gaps for name, gaps in report.items() if gaps}
        self.assertEqual(offending, {}, "built-ins omit authored schema options")

    def test_gap_census_matches_recorded_baseline(self) -> None:
        computed = {name: gaps for name, doc in self.documents() if (gaps := _missing_authored(doc))}
        self.assertEqual(computed, BASELINE_GAPS)

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

    @unittest.expectedFailure
    def test_defaults_document_owns_only_schema_paths(self) -> None:
        document = json.loads((THEMES / "defaults" / "v1.json").read_text(encoding="utf-8"))
        violations = _defaults_violations(document)
        self.assertEqual(violations, [], "defaults document owns paths outside the schema contract")

    def test_defaults_violations_match_recorded_baseline(self) -> None:
        document = json.loads((THEMES / "defaults" / "v1.json").read_text(encoding="utf-8"))
        self.assertEqual(_defaults_violations(document), sorted(EXPECTED_DEFAULTS_VIOLATIONS))


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


if __name__ == "__main__":
    unittest.main()
