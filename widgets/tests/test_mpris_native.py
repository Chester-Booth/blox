"""Test the real native MPRIS adaptor against a private, silent fixture player."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

FIXTURE = Path(__file__).with_name("fixtures") / "mpris_fixture.py"


@unittest.skipUnless(shutil.which("dbus-run-session") and shutil.which("quickshell")
                     and importlib.util.find_spec("gi"), "Private MPRIS verification needs dbus-run-session, Quickshell and Gio")
class NativeMprisTests(unittest.TestCase):
    def test_music_snapshots_actions_seek_artwork_and_fresh_reveal(self):
        environment = dict(os.environ)
        for name in ("DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY"):
            environment.pop(name, None)
        environment["BLOX_MPRIS_PRIVATE_FIXTURE"] = "1"
        result = subprocess.run(["dbus-run-session", "--", sys.executable, str(FIXTURE), "run"],
                                env=environment, capture_output=True, text=True, timeout=25)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("MPRIS-FIXTURE-PASSED", output)
        self.assertIn('"SetPosition"', output)
        self.assertNotIn("MPRIS-FIXTURE-FAILED", output)
        self.assertNotIn("TypeError", output)
        self.assertNotIn("ReferenceError", output)


if __name__ == "__main__":
    unittest.main()
