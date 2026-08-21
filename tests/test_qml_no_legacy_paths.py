"""QML must address helpers through the running shell, never the checkout."""

import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
SHELL = REPOSITORY / "shell"
FORBIDDEN = ".config/quickshell/blox"


class QmlPathHygieneTests(unittest.TestCase):
    def test_no_qml_references_the_legacy_checkout_path(self):
        offenders = []
        for qml in sorted(SHELL.rglob("*.qml")):
            if FORBIDDEN in qml.read_text(encoding="utf-8"):
                offenders.append(str(qml.relative_to(SHELL)))
        self.assertEqual([], offenders,
                         "hard-coded checkout paths break the installed product: "
                         + ", ".join(offenders))

    def test_theme_and_launcher_helpers_use_shelldir(self):
        controller = (SHELL / "modules/LauncherMainController.qml").read_text(encoding="utf-8")
        self.assertNotIn('Quickshell.env("HOME")', controller)
        self.assertIn('Quickshell.shellDir + "/scripts/theme/themectl.sh"', controller)


if __name__ == "__main__":
    unittest.main()
