from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.editor import EditorSettingsFailure, apply_fragment, read_settings_values, remove_members, restore_settings


class EditorSettingsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.settings = self.root / "Code/User/settings.json"
        self.fragment = {
            "workbench.colorTheme": "Dark 2026",
            "editor.fontFamily": "MartianMono Nerd Font",
            "workbench.experimental.modernUI": True,
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
        self.assertIn('"editor.fontSize": 10', text)
        self.assertIn('"workbench.experimental.modernUI": true', text)
        self.assertIn('"workbench.colorTheme": "Dark 2026"', text)

    def test_new_settings_are_created_and_repeated_apply_updates_owned_values(self) -> None:
        apply_fragment(self.settings, self.fragment)
        changed = dict(self.fragment)
        changed["workbench.experimental.modernUI"] = False
        apply_fragment(self.settings, changed)
        self.assertIn('"workbench.experimental.modernUI": false', self.settings.read_text(encoding="utf-8"))

    def test_non_atomic_write_preserves_existing_file_inode(self) -> None:
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('{"theme":"One Dark"}\n', encoding="utf-8")
        inode = os.stat(self.settings).st_ino

        apply_fragment(self.settings, {"theme": "Blox: Catppuccin Mocha"}, atomic=False)

        self.assertEqual(inode, os.stat(self.settings).st_ino)
        self.assertEqual("Blox: Catppuccin Mocha", read_settings_values(self.settings, ("theme",))["theme"]["value"])

    def test_symlink_target_is_updated_without_replacing_the_link(self) -> None:
        target = self.root / "target.json"
        target.write_text("{}\n", encoding="utf-8")
        self.settings.parent.mkdir(parents=True)
        self.settings.symlink_to(target)
        apply_fragment(self.settings, self.fragment)
        self.assertTrue(self.settings.is_symlink())
        self.assertIn('"editor.fontFamily": "MartianMono Nerd Font"', target.read_text(encoding="utf-8"))

    def test_read_remove_and_restore_preserve_jsonc_and_explicit_presence(self) -> None:
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text(
            '{\n'
            '  // keep this comment\n'
            '  "files.autoSave": "afterDelay",\n'
            '  "workbench.experimental.modernUI": true,\n'
            '  "editor.fontFamily": "Old Font",\n'
            '}\n',
            encoding="utf-8",
        )
        values = read_settings_values(self.settings, ("workbench.experimental.modernUI", "editor.fontSize", "editor.fontFamily"))
        self.assertEqual({"present": True, "value": True}, values["workbench.experimental.modernUI"])
        self.assertEqual({"present": False}, values["editor.fontSize"])
        updated = remove_members(self.settings.read_text(encoding="utf-8"), ["workbench.experimental.modernUI"])
        self.assertNotIn("workbench.experimental.modernUI", updated)
        self.assertIn("// keep this comment", updated)
        restore_settings(self.settings, {"workbench.experimental.modernUI": False}, ["editor.fontFamily"])
        text = self.settings.read_text(encoding="utf-8")
        self.assertIn('"workbench.experimental.modernUI": false', text)
        self.assertNotIn("editor.fontFamily", text)
        self.assertIn('"files.autoSave": "afterDelay"', text)

    def test_jsonc_nested_comments_and_trailing_commas_are_decoded(self) -> None:
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text(
            '{\n'
            '  "workbench.colorCustomizations": {\n'
            '    // keep nested comment while reading\n'
            '    "editor.background": "#000000",\n'
            '  },\n'
            '}\n',
            encoding="utf-8",
        )
        apply_fragment(self.settings, {"workbench.colorCustomizations": {"editor.foreground": "#ffffff"}})
        values = read_settings_values(self.settings, ("workbench.colorCustomizations",))
        self.assertEqual({"editor.background": "#000000", "editor.foreground": "#ffffff"}, values["workbench.colorCustomizations"]["value"])

    def test_legacy_duplicate_commas_are_decoded_for_migration(self) -> None:
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text(
            '{\n'
            '  "editor.fontFamily": "Old Font"\n'
            ',\n'
            '  "workbench.colorCustomizations": {"editor.background": "#000000"}\n'
            ',\n'
            '  "workbench.colorTheme": "Dark 2026",\n'
            '}\n',
            encoding="utf-8",
        )
        values = read_settings_values(self.settings, ("editor.fontFamily", "workbench.colorTheme"))
        self.assertEqual("Old Font", values["editor.fontFamily"]["value"])
        self.assertEqual("Dark 2026", values["workbench.colorTheme"]["value"])
        apply_fragment(self.settings, {"editor.fontFamily": "New Font"})
        text = self.settings.read_text(encoding="utf-8")
        self.assertIn('"editor.fontFamily": "New Font"', text)
        self.assertIn('"workbench.colorTheme": "Dark 2026"', text)
        self.assertNotIn('"editor.fontFamily": "New Font"\n,\n', text)

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
