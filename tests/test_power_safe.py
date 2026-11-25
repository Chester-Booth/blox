"""Focused behavioural tests for shell/scripts/power/safe.sh."""

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SAFE_SCRIPT = REPO_ROOT / "shell/scripts/power/safe.sh"


def write_executable(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class PowerSafeTests(unittest.TestCase):
    def make_sandbox(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        log_file = root / "calls.log"
        log_file.write_text("", encoding="utf-8")
        # Default benign stubs so tests never touch the live desktop session.
        write_executable(fake_bin / "hyprctl", 'if [[ "$1" == "clients" ]]; then printf "[]\\n"; fi\n')
        write_executable(fake_bin / "notify-send", 'printf "notify:%s\\n" "$*" >> "$FAKE_LOG"\n')
        write_executable(fake_bin / "ktr", 'printf "ktr:%s\\n" "$*" >> "$FAKE_LOG"\n')
        write_executable(fake_bin / "pgrep", "exit 1\n")
        write_executable(fake_bin / "hyprlock", 'printf "hyprlock:%s\\n" "$*" >> "$FAKE_LOG"\nsleep 10\n')
        write_executable(fake_bin / "systemctl", 'printf "systemctl:%s\\n" "$*" >> "$FAKE_LOG"\nexit 0\n')
        write_executable(
            fake_bin / "busctl",
            'printf \'{"type":"a(ssssuu)","data":[[]]}\\n\'\n',
        )
        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
        env["FAKE_LOG"] = str(log_file)
        return root, fake_bin, log_file, env

    def run_safe(self, args, env):
        return subprocess.run(
            ["bash", str(SAFE_SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_inhibitors_filters_to_block_mode_and_matching_scope_only(self):
        _, fake_bin, _, env = self.make_sandbox()
        inhibitors = {
            "type": "a(ssssuu)",
            "data": [[
                ["idle", "Blox", "Awake mode", "block", 1000, 5282],
                ["sleep", "hypridle", "Delay sleep for lock", "delay", 1000, 5253],
                ["shutdown", "code", "Ensure clean shutdown", "delay", 1000, 575427],
                ["sleep", "T3 Code", "Agents are working", "block", 1000, 939750],
                ["shutdown:sleep", "fwupd", "Installing firmware", "block", 0, 1200],
            ]],
        }
        write_executable(fake_bin / "busctl", f"printf '%s\\n' '{json.dumps(inhibitors)}'\n")

        result = self.run_safe(["inhibitors"], env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual([item["who"] for item in payload["sleep"]], ["T3 Code", "fwupd"])
        self.assertEqual([item["who"] for item in payload["shutdown"]], ["T3 Code", "fwupd"])
        self.assertEqual(payload["micro"], [])

    def test_sleep_inhibitor_also_blocks_shutdown_and_update_shutdown_precheck(self):
        _, fake_bin, log_file, env = self.make_sandbox()
        inhibitors = {
            "type": "a(ssssuu)",
            "data": [[
                ["sleep", "T3 Code", "Agents are working", "block", 1000, 578100],
            ]],
        }
        write_executable(fake_bin / "busctl", f"printf '%s\\n' '{json.dumps(inhibitors)}'\n")

        shutdown_result = self.run_safe(["--json", "shutdown"], env)
        self.assertEqual(shutdown_result.returncode, 1)
        shutdown_payload = json.loads(shutdown_result.stdout)
        self.assertEqual(shutdown_payload["code"], "inhibited")
        self.assertEqual(shutdown_payload["data"]["action"], "shutdown")
        self.assertEqual(shutdown_payload["data"]["items"][0]["who"], "T3 Code")

        precheck_result = self.run_safe(["--json", "precheck", "update-shutdown"], env)
        self.assertEqual(precheck_result.returncode, 1)
        precheck_payload = json.loads(precheck_result.stdout)
        self.assertEqual(precheck_payload["code"], "inhibited")
        self.assertEqual(precheck_payload["data"]["action"], "update-shutdown")
        self.assertNotIn("systemctl:", log_file.read_text(encoding="utf-8"))

    def test_inhibited_sleep_returns_structured_json_without_locking_screen(self):
        _, fake_bin, log_file, env = self.make_sandbox()
        inhibitors = {
            "type": "a(ssssuu)",
            "data": [[
                ["sleep", "T3 Code", "Agents are working", "block", 1000, 578100],
            ]],
        }
        write_executable(fake_bin / "busctl", f"printf '%s\\n' '{json.dumps(inhibitors)}'\n")

        result = self.run_safe(["--json", "sleep"], env)
        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["code"], "inhibited")
        self.assertEqual(payload["data"]["action"], "sleep")
        self.assertEqual(payload["data"]["items"][0]["who"], "T3 Code")
        self.assertEqual(payload["data"]["items"][0]["why"], "Agents are working")
        self.assertEqual(payload["data"]["items"][0]["meta"], "PID 578100")

        calls = log_file.read_text(encoding="utf-8")
        self.assertNotIn("hyprlock:", calls, "Inhibited sleep must not lock the screen")
        self.assertNotIn("systemctl:", calls)

    def test_ignore_inhibitors_bypasses_precheck_and_passes_dash_i(self):
        _, fake_bin, log_file, env = self.make_sandbox()
        inhibitors = {
            "type": "a(ssssuu)",
            "data": [[
                ["sleep", "T3 Code", "Agents are working", "block", 1000, 578100],
            ]],
        }
        write_executable(fake_bin / "busctl", f"printf '%s\\n' '{json.dumps(inhibitors)}'\n")

        result = self.run_safe(["--json", "--ignore-inhibitors", "sleep"], env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        calls = log_file.read_text(encoding="utf-8")
        self.assertIn("hyprlock:--immediate-render", calls)
        self.assertIn("systemctl:suspend-then-hibernate -i", calls)

    def test_lock_spawns_hyprlock_detached_and_returns_immediately(self):
        _, _, log_file, env = self.make_sandbox()

        result = self.run_safe(["--json", "lock"], env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["data"]["action"], "lock")
        self.assertIn("hyprlock:--immediate-render", log_file.read_text(encoding="utf-8"))

    def test_systemctl_failure_keeps_first_meaningful_error_line(self):
        _, fake_bin, _, env = self.make_sandbox()
        write_executable(
            fake_bin / "systemctl",
            'printf "Call to Hibernate failed: Not enough swap space for hibernation\\nAlternatively, try something else.\\n" >&2\nexit 1\n',
        )

        result = self.run_safe(["--json", "hibernate"], env)
        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["code"], "failed")
        self.assertIn("Not enough swap space for hibernation", payload["message"])
        self.assertNotIn("Alternatively", payload["message"])


if __name__ == "__main__":
    unittest.main()
