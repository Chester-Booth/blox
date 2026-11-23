import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from shell.scripts import bloxctl
from shell.scripts.settings_document import SettingsDocument
from shell.scripts.settings_runtime import run_request


REPOSITORY = Path(__file__).resolve().parents[1]
FIXTURE_PATH = REPOSITORY / "tests/fixtures/settings-owner-results.json"


class SettingsRuntimeTests(unittest.TestCase):
    def test_draft_sections_commit_atomically_and_reject_stale_revision(self):
        with tempfile.TemporaryDirectory() as temporary:
            document = SettingsDocument(Path(temporary))
            initial = document.get().data
            bar = initial["bar"]
            bar["layout"]["position"] = "left"
            osd = initial["osd"]
            osd["position"] = "top-left"
            request = {"sections": {"bar": bar, "osd": osd}, "expectedRevision": 0}
            saved = run_request("set-sections", json.dumps(request), document)
            self.assertTrue(saved["ok"], saved)
            self.assertEqual(document.get().revision, 1)
            self.assertEqual(document.get().data["bar"]["layout"]["position"], "left")
            before = (Path(temporary) / "blox/settings.json").read_bytes()
            stale = run_request("set-sections", json.dumps(request), document)
            self.assertEqual(stale["code"], "conflict")
            self.assertEqual((Path(temporary) / "blox/settings.json").read_bytes(), before)

    def run_runtime_script(self, root: Path, operation: str, request: dict) -> dict:
        environment = os.environ.copy()
        environment["XDG_CONFIG_HOME"] = str(root)
        completed = subprocess.run(
            [sys.executable, str(REPOSITORY / "shell/scripts/settings_runtime.py"), operation,
             json.dumps(request, separators=(",", ":"))],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def test_isolated_success_and_stale_set_agree_with_cli_and_leave_file_unchanged(self):
        fixtures = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            success = self.run_runtime_script(root, "set", {
                "path": "bar.layout.position",
                "valueJson": json.dumps("right"),
                "expectedRevision": 0,
            })
            path = root / "blox" / "settings.json"
            committed_bytes = path.read_bytes()
            stale = self.run_runtime_script(root, "set", {
                "path": "bar.layout.position",
                "valueJson": json.dumps("left"),
                "expectedRevision": 0,
            })

            self.assertEqual(path.read_bytes(), committed_bytes)
            document = json.loads(committed_bytes)
            self.assertEqual(document["revision"], 1)
            self.assertEqual(document["bar"]["layout"]["position"], "right")

        for actual, fixture in ((success, fixtures["success"]), (stale, fixtures["conflict"])):
            self.assertEqual(actual["code"], fixture["code"])
            self.assertEqual(actual["data"]["revision"], fixture["data"]["revision"])
            self.assertEqual(actual["data"]["changedComponents"], fixture["data"]["changedComponents"])

        for actual, argv, expected_exit in (
            (success, ["settings", "set", "bar.layout.position", json.dumps("right"), "--revision", "0", "--json"], bloxctl.EXIT_OK),
            (stale, ["settings", "set", "bar.layout.position", json.dumps("left"), "--revision", "0", "--json"], bloxctl.EXIT_CONFLICT),
        ):
            pending = bloxctl.result(True, "pending", "", {"requestId": "isolated-test"})
            replies = [
                subprocess.CompletedProcess(["ipc"], 0, json.dumps(pending), ""),
                subprocess.CompletedProcess(["ipc"], 0, json.dumps(actual), ""),
            ]
            with patch.object(bloxctl.subprocess, "run", side_effect=replies):
                code, cli_result, as_json, printed = bloxctl.run(argv)
            self.assertEqual(code, expected_exit)
            self.assertTrue(as_json)
            self.assertFalse(printed)
            self.assertEqual(cli_result["code"], actual["code"])
            self.assertEqual(cli_result["data"]["revision"], actual["data"]["revision"])
            self.assertEqual(cli_result["data"]["changedComponents"], actual["data"]["changedComponents"])

    def test_success_conflict_and_validation_failure_match_the_shared_client_contract(self):
        fixtures = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temporary:
            document = SettingsDocument(temporary)
            success = run_request("set", json.dumps({
                "path": "bar.layout.position",
                "valueJson": json.dumps("right"),
                "expectedRevision": 0,
            }), document)
            conflict = run_request("set", json.dumps({
                "path": "bar.layout.position",
                "valueJson": json.dumps("left"),
                "expectedRevision": 0,
            }), document)
            invalid = run_request("set", json.dumps({
                "path": "bar.layout.position",
                "valueJson": json.dumps("diagonal"),
                "expectedRevision": 1,
            }), document)

        for name, action in (("success", success), ("conflict", conflict), ("validationFailure", invalid)):
            expected = fixtures[name]
            self.assertEqual(action["code"], expected["code"])
            self.assertEqual(action["data"]["revision"], expected["data"]["revision"])
            self.assertEqual(action["data"]["changedComponents"], expected["data"]["changedComponents"])
        self.assertTrue(success["ok"])
        self.assertEqual(success["data"]["commitState"], "committed")
        self.assertEqual(conflict["code"], "conflict")
        self.assertEqual(conflict["message"], "settings revision conflict")
        self.assertTrue(conflict["data"]["conflict"])
        self.assertEqual(invalid["code"], "invalid-data")
        self.assertEqual(invalid["data"]["commitState"], "not-committed")
        self.assertEqual(invalid["data"]["error"]["code"], "invalid-data")

    def test_get_reports_defaults_without_creating_the_settings_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            action = run_request("get", "{}", SettingsDocument(root))
            self.assertEqual(action["code"], "ok")
            self.assertEqual(action["data"]["schemaVersion"], 1)
            self.assertEqual(action["data"]["revision"], 0)
            self.assertEqual(action["data"]["commitState"], "not-applicable")
            self.assertFalse((root / "blox").exists())

    def test_runtime_script_entrypoint_uses_an_isolated_xdg_root(self):
        script = REPOSITORY / "shell/scripts/settings_runtime.py"
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["XDG_CONFIG_HOME"] = temporary
            completed = subprocess.run(
                [sys.executable, str(script), "get", "{}"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            action = json.loads(completed.stdout)
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(action["code"], "ok")
            self.assertEqual(action["data"]["revision"], 0)
            self.assertFalse((Path(temporary) / "blox").exists())

    def test_reset_uses_expected_revision_and_reports_changed_components(self):
        with tempfile.TemporaryDirectory() as temporary:
            document = SettingsDocument(temporary)
            set_action = run_request("set", json.dumps({
                "path": "bar.layout.position",
                "valueJson": json.dumps("right"),
                "expectedRevision": 0,
            }), document)
            reset = run_request("reset", json.dumps({"section": "bar", "expectedRevision": 1}), document)
        self.assertTrue(set_action["ok"])
        self.assertTrue(reset["ok"])
        self.assertEqual(reset["data"]["revision"], 2)
        self.assertEqual(reset["data"]["changedComponents"], ["bar"])
        self.assertEqual(reset["data"]["settings"]["bar"]["layout"]["position"], "left")


if __name__ == "__main__":
    unittest.main()
