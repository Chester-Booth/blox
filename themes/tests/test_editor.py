from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.editor import EditorSettingsFailure, apply_fragment


class EditorSettingsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.settings = self.root / "Code/User/settings.json"
        self.fragment = {
            "workbench.colorTheme": "Dark 2026",
            "editor.fontFamily": "MartianMono Nerd Font",
            "editor.fontSize": 12,
            "workbench.colorCustomizations": {
                "editor.background": "#101114",
                "editor.foreground": "#cdd6f4",
            },
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_apply_preserves_comments_unrelated_settings_and_colours(self) -> None:
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text(
            '{\n  // keep this comment\n  "files.autoSave": "afterDelay",\n  "editor.fontSize": 10,\n  "workbench.colorCustomizations": {"terminal.background": "#000000"},\n}\n',
            encoding="utf-8",
        )
        apply_fragment(self.settings, self.fragment)
        text = self.settings.read_text(encoding="utf-8")
        self.assertIn("// keep this comment", text)
        self.assertIn('"files.autoSave": "afterDelay"', text)
        self.assertIn('"terminal.background": "#000000"', text)
        self.assertIn('"editor.background": "#101114"', text)
        self.assertIn('"editor.fontSize": 12', text)
        self.assertIn('"workbench.colorTheme": "Dark 2026"', text)

    def test_new_settings_are_created_and_repeated_apply_updates_owned_values(self) -> None:
        apply_fragment(self.settings, self.fragment)
        changed = dict(self.fragment)
        changed["editor.fontSize"] = 14
        apply_fragment(self.settings, changed)
        self.assertIn('"editor.fontSize": 14', self.settings.read_text(encoding="utf-8"))

    def test_symlink_target_is_updated_without_replacing_the_link(self) -> None:
        target = self.root / "target.json"
        target.write_text("{}\n", encoding="utf-8")
        self.settings.parent.mkdir(parents=True)
        self.settings.symlink_to(target)
        apply_fragment(self.settings, self.fragment)
        self.assertTrue(self.settings.is_symlink())
        self.assertIn('"editor.fontSize": 12', target.read_text(encoding="utf-8"))

    def test_broken_symlink_and_incompatible_workbench_are_unchanged(self) -> None:
        self.settings.parent.mkdir(parents=True)
        self.settings.symlink_to(self.root / "missing.json")
        with self.assertRaises(EditorSettingsFailure):
            apply_fragment(self.settings, self.fragment)

        self.settings.unlink()
        original = '{"workbench.colorCustomizations": false}\n'
        self.settings.write_text(original, encoding="utf-8")
        with self.assertRaises(EditorSettingsFailure):
            apply_fragment(self.settings, self.fragment)
        self.assertEqual(original, self.settings.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
