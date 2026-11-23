"""Verify the compact standalone QML vectors against the authoritative Python validator.

Run with python -m unittest tests.test_settings_widget_validation_fixture -v.
The separate compact-widget-settings/regressions.py runner still generates and
compares its full 1,228-profile corpus. These 69 shared vectors cover the relevant
Unicode, JSON key, workspace and command boundaries without storing long strings.
"""

import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "widgets/lib"))

from blox_widgets.model import ValidationError, validate_profile


def expand_cases(data):
    """Apply the same literal replacements and string recipes as the QML fixture loader."""
    for sample in data["cases"]:
        widget = copy.deepcopy(data["bases"][sample["kind"]])
        for change in sample["changes"]:
            parent = widget
            for key in change["path"][:-1]:
                parent = parent[key]
            if "keyText" in change:
                value = {change["keyText"] * change["repeat"]: copy.deepcopy(change["value"])}
            elif "text" in change:
                value = change.get("prefix", "") + change["text"] * change["repeat"]
            else:
                value = copy.deepcopy(change["value"])
            parent[change["path"][-1]] = value
        yield {**sample, "widget": widget}


class SettingsWidgetValidationFixtureTests(unittest.TestCase):
    def test_shared_boundaries_match_python(self):
        data = json.loads((ROOT / "tests/qml/validation-cases.json").read_text())
        self.assertEqual(data["version"], 1)
        samples = list(expand_cases(data))
        self.assertEqual(len(samples), 69)
        self.assertEqual(len({sample["name"] for sample in samples}), len(samples))
        self.assertEqual(sum(sample["backendValid"] is True for sample in samples), 32)
        self.assertEqual(sum(sample["backendValid"] is False for sample in samples), 37)
        self.assertEqual([sample["name"] for sample in samples if sample.get("formatCase")],
                         ["timezone-authoritative"])
        for sample in samples:
            with self.subTest(case=sample["name"]):
                document = {"schemaVersion": 1, "widgets": [sample["widget"]]}
                if sample["backendValid"]:
                    validate_profile(document)
                else:
                    with self.assertRaises(ValidationError):
                        validate_profile(document)


if __name__ == "__main__":
    unittest.main()
