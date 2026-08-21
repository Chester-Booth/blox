import contextlib
import importlib.util
import io
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[1]
MODULE_PATH = REPOSITORY / "shell/scripts/bloxctl.py"
SPEC = importlib.util.spec_from_file_location("bloxctl", MODULE_PATH)
bloxctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bloxctl)


class BloxctlTests(unittest.TestCase):
    def run_cli(self, args, completed=None):
        output = io.StringIO()
        with patch.object(bloxctl.subprocess, "run", return_value=completed) as run, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = bloxctl.main(args)
        return code, json.loads(output.getvalue()), run

    def test_status_uses_the_single_shell_action_owner(self):
        action = {
            "version": 1,
            "ok": True,
            "code": "ok",
            "message": "",
            "data": {"updates": {"totalCount": 2, "capability": {"available": True}}},
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["status", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "status"])

    def test_shell_unavailable_has_a_stable_exit_class(self):
        completed = subprocess.CompletedProcess(["ipc"], 1, "", "not running")
        code, output, _ = self.run_cli(["status", "--json"], completed)
        self.assertEqual(code, bloxctl.EXIT_UNAVAILABLE)
        self.assertEqual(output["code"], "unavailable")
        self.assertIsNone(output["data"])

    def test_malformed_owner_result_is_invalid_data(self):
        completed = subprocess.CompletedProcess(["ipc"], 0, "not json", "")
        code, output, _ = self.run_cli(["status", "--json"], completed)
        self.assertEqual(code, bloxctl.EXIT_INVALID_DATA)
        self.assertEqual(output["code"], "invalid-data")

    def test_later_groups_are_public_but_not_claimed_early(self):
        code, output, _ = self.run_cli(["settings", "--json"])
        self.assertEqual(code, bloxctl.EXIT_UNAVAILABLE)
        self.assertEqual(output["code"], "unavailable")
        self.assertIn("later phase", output["message"])

    def test_status_json_does_not_include_presentation_fields(self):
        action = {
            "version": 1,
            "ok": True,
            "code": "ok",
            "message": "",
            "data": {"network": {"signal": 80, "capability": {"available": True}}},
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, _ = self.run_cli(["status", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertNotIn("tooltip", json.dumps(output))
        self.assertNotIn("label", json.dumps(output))


if __name__ == "__main__":
    unittest.main()
