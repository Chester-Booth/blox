"""Exercise the real standalone renderer in an isolated subprocess."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreviewTests(unittest.TestCase):
    def test_verification_without_a_desktop_or_session_bus(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            theme = directory / "theme.json"
            theme.write_text(json.dumps({
                "colours": {"background": "#242424", "surface": "#1e1e1e", "surface_alt": "#3b3c4a",
                    "foreground": "#cdd6f4", "muted": "#a6adc8", "accent": "#89b4fa", "border": "#3b3c4a",
                    "teal": "#94e2d5", "mauve": "#f5c2e7", "warning": "#f9e2af", "danger": "#f38ba8"},
                "fonts": {"ui": "Sans Serif", "mono": "monospace"},
                "shape": {"radius_scale": 0, "density_scale": 0.75}}))
            output = directory / "captures"
            environment = {**os.environ, "DISPLAY": ":invalid", "WAYLAND_DISPLAY": "invalid",
                           "DBUS_SESSION_BUS_ADDRESS": "unix:path=/invalid", "QT_QPA_PLATFORMTHEME": "gtk3"}
            result = subprocess.run([sys.executable, str(ROOT / "preview.py"), "--verify", "--theme", str(theme),
                                     "--output", str(output)], env=environment, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            report = json.loads((output / "verification.json").read_text())
            self.assertTrue(report["fixtureDataOnly"])
            self.assertTrue(report["galleryReady"])
            self.assertFalse(report["nativeProviderAdaptersLoaded"])
            self.assertEqual(report["fixtureActionsRecorded"], 0)
            self.assertEqual(report["nativeCases"], 14)
            self.assertEqual(report["renderedCases"], 192)
            self.assertEqual({row["presentation"] for row in report["frames"]}, {"open", "compact"})
            self.assertEqual({row["shape"] for row in report["frames"]}, {"minimum", "theme", "maximum"})
            self.assertTrue(all(row["phase"] == "visible" for row in report["frames"]))
            self.assertIn("example-music", {row["case"] for row in report["frames"]})
            self.assertIn("fixture-native-open-theme.png", report["artifacts"])
            self.assertIn("fixture-native-compact-maximum.png", report["artifacts"])
            for artifact in report["artifacts"]:
                content = (output / artifact).read_bytes()
                self.assertEqual(content[:8], b"\x89PNG\r\n\x1a\n")
                self.assertGreater(len(content), 5000)


if __name__ == "__main__":
    unittest.main()
