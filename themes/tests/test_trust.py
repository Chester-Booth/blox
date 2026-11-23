from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme import portability
from blox_theme.core import load_theme, widget_model
from blox_theme.trust import TrustFailure, safe_template_output, strip_widget_document, trust_record_allows_commands, write_template_output


class TrustTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.library = self.root / "library"
        _, source = load_theme("catppuccin-mocha")
        self.theme = copy.deepcopy(source)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_import_disables_commands_and_keeps_trust_metadata_outside_theme(self) -> None:
        self.theme["id"] = "untrusted-widgets"
        widget = widget_model().default_widget('terminal', 'terminal',
            {'command': ['/bin/echo', 'review me']})
        self.theme['widgets'] = {'schemaVersion': 1, 'widgets': [widget]}
        source = self.root / "untrusted.json"
        source.write_text(json.dumps(self.theme), encoding="utf-8")

        data, warnings = portability.import_theme(source, self.library)
        saved = json.loads(Path(data["path"]).read_text(encoding="utf-8"))
        item = saved['widgets']['widgets'][0]
        self.assertFalse(item['enabled'])
        self.assertEqual(widget['settings'], item['settings'])
        self.assertEqual(data['executable_fields'], ['widgets.widgets[0].settings.command'])
        self.assertTrue(any("disabled executable fields" in warning for warning in warnings))
        record_path = self.library / "trust/themes/untrusted-widgets.json"
        self.assertEqual(record_path, Path(data["trust_record"]))
        record = json.loads(record_path.read_text(encoding="utf-8"))
        self.assertFalse(record["trusted"])
        self.assertEqual(data["content_sha256"], record["content_sha256"])
        self.assertFalse(trust_record_allows_commands(Path(data["path"]), self.library))

    def test_explicit_trust_is_revoked_when_saved_content_changes(self) -> None:
        self.theme["id"] = "hash-checked"
        source = self.root / "hash-checked.json"
        source.write_text(json.dumps(self.theme), encoding="utf-8")
        data, _ = portability.import_theme(source, self.library)
        record_path = self.library / "trust/themes/hash-checked.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["trusted"] = True
        record_path.write_text(json.dumps(record), encoding="utf-8")
        theme_path = Path(data["path"])
        self.assertTrue(trust_record_allows_commands(theme_path, self.library))
        theme_path.write_text(theme_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        self.assertFalse(trust_record_allows_commands(theme_path, self.library))

    def test_command_output_import_requires_execution_consent(self) -> None:
        widget = widget_model().default_widget('command', 'command-output',
            {'command': ['/bin/echo', 'review me']})
        original = {'schemaVersion': 1, 'widgets': [widget]}
        sanitised, fields = strip_widget_document(original)
        self.assertEqual(['widgets[0].settings.command'], fields)
        self.assertFalse(sanitised['widgets'][0]['enabled'])
        self.assertEqual(widget['settings'], sanitised['widgets'][0]['settings'])
        self.assertTrue(original['widgets'][0]['enabled'])

    def test_template_output_stays_below_approved_root(self) -> None:
        approved = self.root / "approved"
        approved.mkdir()
        self.assertEqual(approved / "nested/output.txt", safe_template_output(approved, "nested/output.txt"))
        write_template_output(approved, "nested/output.txt", "safe")
        self.assertEqual("safe", (approved / "nested/output.txt").read_text(encoding="utf-8"))
        for requested in ("../escape.txt", "/tmp/escape.txt", "nested/../escape.txt", ""):
            with self.subTest(requested=requested):
                with self.assertRaises(TrustFailure):
                    safe_template_output(approved, requested)

        outside = self.root / "outside"
        outside.mkdir()
        (approved / "link").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(TrustFailure):
            safe_template_output(approved, "link/escape.txt")
        self.assertFalse((outside / "escape.txt").exists())

    def test_data_only_import_has_no_trust_warning_or_executable_fields(self) -> None:
        self.theme["id"] = "data-only"
        source = self.root / "data-only.json"
        source.write_text(json.dumps(self.theme), encoding="utf-8")
        data, warnings = portability.import_theme(source, self.library)
        self.assertEqual([], data["executable_fields"])
        self.assertFalse(any("disabled executable fields" in warning for warning in warnings))
        self.assertEqual([], json.loads(Path(data["path"]).read_text(encoding="utf-8")).get("widgets", {}).get("widgets", []))


if __name__ == "__main__":
    unittest.main()
