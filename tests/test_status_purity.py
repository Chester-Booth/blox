import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "shell/scripts/status/caffeine.sh"


class CaffeineStatusPurityTests(unittest.TestCase):
    def run_status(self, state_document, hypridle_running):
        with tempfile.TemporaryDirectory(prefix="blox-caffeine-status-") as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "calls.log"
            state_home = root / "state"
            state_file = state_home / "quickshell/caffeine.json"
            if state_document is not None:
                state_file.parent.mkdir(parents=True)
                state_file.write_text(json.dumps(state_document) + "\n", encoding="utf-8")

            self.write_fake(
                fake_bin / "pgrep",
                """#!/usr/bin/env bash
printf 'pgrep %s\\n' "$*" >> "$FAKE_LOG"
if [[ "$FAKE_HYPRIDLE_RUNNING" == "true" ]]; then exit 0; fi
exit 1
""",
            )
            self.write_fake(
                fake_bin / "pkill",
                """#!/usr/bin/env bash
printf 'pkill %s\\n' "$*" >> "$FAKE_LOG"
exit 0
""",
            )
            self.write_fake(
                fake_bin / "hypridle",
                """#!/usr/bin/env bash
printf 'hypridle %s\\n' "$*" >> "$FAKE_LOG"
exit 0
""",
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "HOME": str(root / "home"),
                    "XDG_STATE_HOME": str(state_home),
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "FAKE_LOG": str(log),
                    "FAKE_HYPRIDLE_RUNNING": "true" if hypridle_running else "false",
                }
            )
            before = state_file.read_bytes() if state_file.exists() else None
            result = subprocess.run(
                ["/usr/bin/bash", str(SCRIPT), "status"],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            if before is None:
                self.assertFalse(state_home.exists())
            else:
                self.assertEqual(state_file.read_bytes(), before)
            calls = log.read_text(encoding="utf-8") if log.exists() else ""
            self.assertIn("pgrep -x hypridle", calls)
            self.assertNotIn("pkill", calls)
            self.assertNotIn("hypridle \n", calls)
            self.assertEqual(state_file.exists(), before is not None)
            return json.loads(result.stdout)

    @staticmethod
    def write_fake(path, contents):
        path.write_text(contents, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def test_active_status_does_not_reconcile_hypridle(self):
        payload = self.run_status({"deadline": 4102444800, "mode": "1h"}, True)

        self.assertTrue(payload["active"])
        self.assertTrue(payload["hypridleRunning"])
        self.assertEqual(payload["class"], "warning")
        self.assertFalse(payload["reconciled"])

    def test_expired_status_does_not_remove_state_or_start_hypridle(self):
        payload = self.run_status({"deadline": 1, "mode": "30m"}, False)

        self.assertFalse(payload["active"])
        self.assertFalse(payload["hypridleRunning"])
        self.assertEqual(payload["class"], "warning")
        self.assertFalse(payload["reconciled"])

    def test_status_does_not_create_state_directory_when_no_state_exists(self):
        payload = self.run_status(None, False)

        self.assertFalse(payload["active"])
        self.assertFalse(payload["hypridleRunning"])
        self.assertEqual(payload["class"], "warning")
        self.assertFalse(payload["reconciled"])


if __name__ == "__main__":
    unittest.main()
