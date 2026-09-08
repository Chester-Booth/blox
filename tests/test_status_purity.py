import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "shell/scripts/status/caffeine.sh"
VENDOR_PERFORMANCE_SCRIPT = REPOSITORY / "shell/scripts/status/vendor-performance.sh"
CONTROL_SCRIPT = REPOSITORY / "shell/scripts/control.sh"


class CaffeineStatusPurityTests(unittest.TestCase):
    def run_status(self, state_document, hypridle_running, inhibitor_active=False):
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
            self.write_fake(
                fake_bin / "systemctl",
                """#!/usr/bin/env bash
printf 'systemctl %s\\n' "$*" >> "$FAKE_LOG"
if [[ "$2" == "is-active" ]]; then
    [[ "$FAKE_INHIBITOR_ACTIVE" == "true" ]]
    exit $?
fi
exit 0
""",
            )
            self.write_fake(
                fake_bin / "systemd-run",
                """#!/usr/bin/env bash
printf 'systemd-run %s\\n' "$*" >> "$FAKE_LOG"
exit 0
""",
            )
            self.write_fake(
                fake_bin / "systemd-inhibit",
                """#!/usr/bin/env bash
printf 'systemd-inhibit %s\\n' "$*" >> "$FAKE_LOG"
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
                    "FAKE_INHIBITOR_ACTIVE": "true" if inhibitor_active else "false",
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
            self.assertIn("systemctl --user is-active --quiet blox-caffeine.service", calls)
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
        self.assertFalse(payload["inhibitActive"])
        self.assertEqual(payload["class"], "warning")
        self.assertFalse(payload["reconciled"])

    def test_active_status_is_clear_when_inhibitor_is_active(self):
        payload = self.run_status({"deadline": -1, "mode": "indefinite"}, True, True)

        self.assertTrue(payload["active"])
        self.assertTrue(payload["hypridleRunning"])
        self.assertTrue(payload["inhibitActive"])
        self.assertEqual(payload["class"], "active")
        self.assertIn("Hypridle paused", payload["tooltip"])

    def test_expired_status_does_not_remove_state_or_start_hypridle(self):
        payload = self.run_status({"deadline": 1, "mode": "30m"}, False)

        self.assertFalse(payload["active"])
        self.assertFalse(payload["hypridleRunning"])
        self.assertFalse(payload["inhibitActive"])
        self.assertEqual(payload["class"], "warning")
        self.assertFalse(payload["reconciled"])

    def test_status_does_not_create_state_directory_when_no_state_exists(self):
        payload = self.run_status(None, False)

        self.assertFalse(payload["active"])
        self.assertFalse(payload["hypridleRunning"])
        self.assertFalse(payload["inhibitActive"])
        self.assertEqual(payload["class"], "warning")
        self.assertFalse(payload["reconciled"])


class VendorPerformanceCapabilityTests(unittest.TestCase):
    @staticmethod
    def write_fake(path, contents):
        path.write_text(contents, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def run_status(self, fan_curve_output):
        with tempfile.TemporaryDirectory(prefix="blox-vendor-performance-") as temporary:
            fake_bin = Path(temporary) / "bin"
            fake_bin.mkdir()
            self.write_fake(
                fake_bin / "asusctl",
                """#!/usr/bin/env bash
if [[ "$1 $2" == "profile list" ]]; then
    printf 'Quiet\\nBalanced\\nPerformance\\n'
elif [[ "$1 $2" == "profile get" ]]; then
    printf 'Active profile: Balanced\\n'
elif [[ "$1 $2" == "fan-curve --get-enabled" ]]; then
    printf '%s\\n' "$FAKE_FAN_CURVE_OUTPUT"
fi
""",
            )
            environment = os.environ.copy()
            environment.update({"PATH": f"{fake_bin}:/usr/bin:/bin", "FAKE_FAN_CURVE_OUTPUT": fan_curve_output})
            result = subprocess.run(
                ["/usr/bin/bash", str(VENDOR_PERFORMANCE_SCRIPT)],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            return json.loads(result.stdout)

    def test_asusctl_error_text_is_not_a_fan_curve_capability(self):
        payload = self.run_status("Error: org.freedesktop.DBus.Error.UnknownInterface")
        self.assertFalse(payload["fanCurveCapability"]["available"])
        self.assertEqual("fan-curves-unsupported", payload["fanCurveCapability"]["reason"])

    def test_supported_custom_fan_curves_are_typed(self):
        payload = self.run_status("CPU: enabled: true")
        self.assertTrue(payload["fanCurveCapability"]["canChange"])
        self.assertTrue(payload["fanCurveEnabled"])
        self.assertEqual("platform-profile", payload["profileControlDomain"])

    def test_fan_curve_action_targets_the_active_profile(self):
        with tempfile.TemporaryDirectory(prefix="blox-fan-curve-action-") as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "calls.log"
            self.write_fake(
                fake_bin / "asusctl",
                """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_LOG"
if [[ "$1 $2" == "profile get" ]]; then printf 'Active profile: Quiet\\n'; fi
""",
            )
            environment = os.environ.copy()
            environment.update({"PATH": f"{fake_bin}:/usr/bin:/bin", "FAKE_LOG": str(log)})
            result = subprocess.run(
                ["/usr/bin/bash", str(CONTROL_SCRIPT), "fan-curves", "on"],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("fan-curve --mod-profile Quiet --enable-fan-curves true", log.read_text(encoding="utf-8"))


class CaffeineReconcileTests(unittest.TestCase):
    def run_reconcile(self, state_document, inhibitor_active=False):
        with tempfile.TemporaryDirectory(prefix="blox-caffeine-reconcile-") as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "calls.log"
            state_home = root / "state"
            state_file = state_home / "quickshell/caffeine.json"
            state_file.parent.mkdir(parents=True)
            if state_document is not None:
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
            self.write_fake(
                fake_bin / "systemctl",
                """#!/usr/bin/env bash
printf 'systemctl %s\\n' "$*" >> "$FAKE_LOG"
if [[ "$2" == "is-active" ]]; then
    if [[ "$FAKE_INHIBITOR_ACTIVE" == "true" || -f "$FAKE_INHIBITOR_MARKER" ]]; then
        exit 0
    fi
    exit 3
fi
if [[ "$2" == "stop" ]]; then
    rm -f "$FAKE_INHIBITOR_MARKER"
fi
exit 0
""",
            )
            self.write_fake(
                fake_bin / "systemd-run",
                """#!/usr/bin/env bash
printf 'systemd-run %s\\n' "$*" >> "$FAKE_LOG"
touch "$FAKE_INHIBITOR_MARKER"
exit 0
""",
            )
            self.write_fake(
                fake_bin / "systemd-inhibit",
                """#!/usr/bin/env bash
printf 'systemd-inhibit %s\\n' "$*" >> "$FAKE_LOG"
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
                    "FAKE_HYPRIDLE_RUNNING": "true",
                    "FAKE_INHIBITOR_ACTIVE": "true" if inhibitor_active else "false",
                    "FAKE_INHIBITOR_MARKER": str(root / "inhibitor-active"),
                }
            )
            result = subprocess.run(
                ["/usr/bin/bash", str(SCRIPT), "reconcile"],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "")
            calls = log.read_text(encoding="utf-8") if log.exists() else ""
            return state_file.exists(), calls

    @staticmethod
    def write_fake(path, contents):
        path.write_text(contents, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def test_active_state_starts_inhibitor_without_touching_state(self):
        state_exists, calls = self.run_reconcile({"deadline": -1, "mode": "indefinite"})

        self.assertTrue(state_exists)
        self.assertIn("systemctl --user start hypridle.service", calls)
        self.assertIn("systemd-run --user --unit=blox-caffeine --collect --quiet systemd-inhibit --what=idle --who=Blox --why=Awake mode --mode=block sleep infinity", calls)
        self.assertNotIn("pkill", calls)
        self.assertNotIn("hypridle \n", calls)

    def test_active_state_keeps_existing_inhibitor(self):
        state_exists, calls = self.run_reconcile({"deadline": -1, "mode": "indefinite"}, True)

        self.assertTrue(state_exists)
        self.assertIn("systemctl --user start hypridle.service", calls)
        self.assertNotIn("systemd-run", calls)
        self.assertNotIn("systemctl --user stop", calls)

    def test_expired_state_is_cleared_and_inhibitor_stops(self):
        state_exists, calls = self.run_reconcile({"deadline": 1, "mode": "30m"})

        self.assertFalse(state_exists)
        self.assertIn("systemctl --user stop blox-caffeine.service", calls)
        self.assertNotIn("systemd-run", calls)

    def test_missing_state_stops_stale_inhibitor(self):
        state_exists, calls = self.run_reconcile(None)

        self.assertFalse(state_exists)
        self.assertIn("systemctl --user stop blox-caffeine.service", calls)
        self.assertNotIn("systemd-run", calls)

    def test_indefinite_action_starts_inhibitor(self):
        with tempfile.TemporaryDirectory(prefix="blox-caffeine-action-") as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            log = root / "calls.log"
            state_home = root / "state"
            self.write_fake(
                fake_bin / "systemctl",
                """#!/usr/bin/env bash
printf 'systemctl %s\\n' "$*" >> "$FAKE_LOG"
if [[ "$2" == "is-active" && -f "$FAKE_INHIBITOR_MARKER" ]]; then exit 0; fi
if [[ "$2" == "is-active" ]]; then exit 3; fi
exit 0
""",
            )
            self.write_fake(
                fake_bin / "systemd-run",
                """#!/usr/bin/env bash
printf 'systemd-run %s\\n' "$*" >> "$FAKE_LOG"
touch "$FAKE_INHIBITOR_MARKER"
exit 0
""",
            )
            self.write_fake(
                fake_bin / "systemd-inhibit",
                """#!/usr/bin/env bash
exit 0
""",
            )
            self.write_fake(
                fake_bin / "hypridle",
                """#!/usr/bin/env bash
exit 0
""",
            )
            self.write_fake(
                fake_bin / "pgrep",
                """#!/usr/bin/env bash
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
                    "FAKE_INHIBITOR_MARKER": str(root / "inhibitor-active"),
                }
            )
            result = subprocess.run(
                ["/usr/bin/bash", str(SCRIPT), "indefinite"],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("systemd-run --user --unit=blox-caffeine --collect --quiet", log.read_text(encoding="utf-8"))
            state_file = state_home / "quickshell/caffeine.json"
            self.assertEqual(json.loads(state_file.read_text(encoding="utf-8"))["mode"], "indefinite")


if __name__ == "__main__":
    unittest.main()
