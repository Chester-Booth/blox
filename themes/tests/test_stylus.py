from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import load_theme, render_theme


class StylusTargetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.path, self.theme = load_theme("catppuccin-mocha")

    def test_package_is_pinned_and_records_style_sets(self) -> None:
        source = json.loads((THEMES / "sources/catppuccin/manifest.json").read_text(encoding="utf-8"))
        self.assertEqual("5ef4cc64231826f46d12a2721fa72571f5aa8a27", source["upstream"]["revision"])
        self.assertEqual(source["upstream"]["revision"], (THEMES / "sources/catppuccin/REVISION").read_text(encoding="utf-8").strip())
        self.assertIn("MIT License", (THEMES / "sources/catppuccin/LICENSE").read_text(encoding="utf-8"))
        self.assertEqual(134, len(source["styles"]))
        self.assertEqual(0, len(source["excluded"]))
        self.assertEqual({"recommended": 92, "unmaintained": 104, "all": 134}, source["style_sets"])
        self.assertEqual(12, sum(record["unmaintained"] for record in source["styles"]))
        self.assertEqual(30, sum(bool(record["remote_imports"]) for record in source["styles"]))
        vendor = json.loads((THEMES / "sources/catppuccin/vendor/manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(source["upstream"]["revision"], vendor["upstream_revision"])
        self.assertEqual(6, len(vendor["imports"]))

    def test_style_sets_control_generated_site_count(self) -> None:
        expected = {"recommended": 92, "unmaintained": 104, "all": 134}
        for style_set, count in expected.items():
            with self.subTest(style_set=style_set):
                theme = copy.deepcopy(self.theme)
                theme["stylus"]["style_set"] = style_set
                files, _ = render_theme(theme)
                manifest = json.loads(files["stylus/manifest.json"])
                self.assertEqual(style_set, manifest["style_set"])
                self.assertEqual(count, len(manifest["styles"]))
                self.assertEqual(expected, manifest["style_set_counts"])

    def test_generated_usercss_is_site_scoped_and_offline(self) -> None:
        files, _ = render_theme(self.theme)
        css = files["stylus/blox-system.user.css"]
        self.assertIn("@name Blox Web Theme", css)
        self.assertIn('@-moz-document regexp("https:\\/\\/github', css)
        self.assertNotIn('regexp("https?://.*")', css)
        self.assertNotIn("userstyles.catppuccin.com", css)
        self.assertNotIn("@import", css)

    def test_generated_usercss_uses_the_active_blox_palette(self) -> None:
        theme = copy.deepcopy(self.theme)
        theme["colours"]["background"] = "#010203"
        theme["colours"]["accent"] = "#070809"
        theme["colours"]["mauve"] = "#040506"
        files, _ = render_theme(theme)
        css = files["stylus/blox-system.user.css"].lower()
        self.assertIn("#010203", css)
        self.assertNotIn("#1e1e2e", css)
        self.assertNotIn("%231e1e2e", css)
        self.assertNotIn("%23cba6f7", css)
        manifest = json.loads(files["stylus/manifest.json"])
        self.assertEqual("background", manifest["palette_mapping"]["base"])
        self.assertEqual(theme["id"], manifest["theme_id"])

    def test_stylus_target_only_writes_its_package(self) -> None:
        theme = copy.deepcopy(self.theme)
        for target in theme["targets"]:
            theme["targets"][target] = target == "stylus"
        files, _ = render_theme(theme)
        self.assertEqual(["stylus/blox-system.user.css", "stylus/manifest.json"], list(files))


if __name__ == "__main__":
    unittest.main()
