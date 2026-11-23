import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


REPOSITORY = Path(__file__).resolve().parents[1]
SETTINGS_RESULTS = json.loads((REPOSITORY / "tests/fixtures/settings-owner-results.json").read_text(encoding="utf-8"))
MODULE_PATH = REPOSITORY / "shell/scripts/bloxctl.py"
SPEC = importlib.util.spec_from_file_location("bloxctl", MODULE_PATH)
bloxctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bloxctl)


class BloxctlTests(unittest.TestCase):
    def run_cli(self, args, completed=None):
        output = io.StringIO()
        if isinstance(completed, list):
            subprocess_patch = patch.object(bloxctl.subprocess, "run", side_effect=completed)
        else:
            subprocess_patch = patch.object(bloxctl.subprocess, "run", return_value=completed)
        with subprocess_patch as run, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
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

    def test_audio_action_uses_the_shell_audio_owner(self):
        action = {
            "version": 1,
            "ok": True,
            "code": "ok",
            "message": "",
            "data": {"operation": "set-volume", "value": 73},
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["audio", "set-volume", "73", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "audio", "set-volume", "73"])

    def test_audio_action_preserves_the_owner_exit_class(self):
        action = {
            "version": 1,
            "ok": False,
            "code": "unavailable",
            "message": "PipeWire is not ready",
            "data": None,
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, _ = self.run_cli(["audio", "toggle-mute", "--json"], completed)
        self.assertEqual(code, bloxctl.EXIT_UNAVAILABLE)
        self.assertEqual(output, action)

    def test_network_action_uses_the_shell_network_owner(self):
        action = {
            "version": 1,
            "ok": True,
            "code": "ok",
            "message": "",
            "data": {"operation": "set-wifi", "value": "off"},
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["network", "set-wifi", "off", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "network", "set-wifi", "off"])

    def test_bluetooth_action_uses_the_shell_bluetooth_owner(self):
        action = {
            "version": 1,
            "ok": True,
            "code": "ok",
            "message": "",
            "data": {"operation": "toggle-enabled", "value": "on"},
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["bluetooth", "toggle-enabled", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "bluetooth", "toggle-enabled", ""])

    def test_gpu_action_uses_the_shell_gpu_owner(self):
        action = {"version": 1, "ok": True, "code": "ok", "message": "", "data": {"mode": "hybrid", "pending": True}}
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["gpu", "set-mode", "hybrid", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "gpu", "set-mode", "hybrid"])

    def test_display_action_uses_the_shell_monitor_owner(self):
        action = {"version": 1, "ok": True, "code": "ok", "message": "", "data": {"monitor": "eDP-1", "refreshId": "144", "pending": True}}
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["display", "set-refresh", "eDP-1", "144", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "monitor", "set-refresh", "eDP-1", "144"])

    def test_gpu_failure_keeps_busy_exit_class_and_details(self):
        action = {"version": 1, "ok": False, "code": "busy", "message": "controller busy", "data": {"failedStep": "apply"}}
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, _ = self.run_cli(["gpu", "set-mode", "integrated", "--json"], completed)
        self.assertEqual(code, bloxctl.EXIT_CONFLICT)
        self.assertEqual(output["data"]["failedStep"], "apply")

    def test_incompatible_gpu_controller_uses_unavailable_exit_class(self):
        action = {
            "version": 1,
            "ok": False,
            "code": "unavailable",
            "message": "GPU mode control is unavailable: controller-incompatible",
            "data": None,
        }
        completed = subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), "")
        code, output, _ = self.run_cli(["gpu", "set-mode", "integrated", "--json"], completed)
        self.assertEqual(code, bloxctl.EXIT_UNAVAILABLE)
        self.assertEqual(output, action)

    def test_ipc_timeout_is_not_reported_as_missing_shell(self):
        with patch.object(bloxctl.subprocess, "run", side_effect=subprocess.TimeoutExpired("ipc", 10)):
            action = bloxctl.call_owner("audio", ["toggle-mute"])
        self.assertEqual(action["code"], "timeout")
        self.assertEqual(bloxctl.exit_code(action), bloxctl.EXIT_CONFLICT)

    def test_malformed_typed_fields_are_rejected_before_exit_mapping(self):
        for changed in ({"version": True}, {"code": []}, {"code": ""}, {"message": {}}):
            with self.subTest(changed=changed):
                action = {**bloxctl.result(False, "failed"), **changed}
                completed = subprocess.CompletedProcess([], 0, json.dumps(action), "")
                with patch.object(bloxctl.subprocess, "run", return_value=completed):
                    reply = bloxctl.call_owner()
                self.assertEqual(reply["code"], "invalid-data")
                self.assertEqual(bloxctl.exit_code(reply), bloxctl.EXIT_INVALID_DATA)

    def test_settings_poll_deadline_is_typed_timeout_with_request_id(self):
        pending = bloxctl.result(True, "pending", "", {"requestId": "awaiting-save"})
        args = SimpleNamespace(settings_command="get")
        with patch.object(bloxctl, "call_owner", return_value=pending), \
                patch.object(bloxctl.time, "monotonic", side_effect=[0, 10]):
            code, action = bloxctl.run_settings(args)
        self.assertEqual(code, bloxctl.EXIT_CONFLICT)
        self.assertEqual(action["code"], "timeout")
        self.assertEqual(action["data"]["requestId"], "awaiting-save")

    def test_caffeine_action_routes_to_shared_shell_owner(self):
        action = bloxctl.result(True, "pending", "", {"operation": "caffeine", "pending": True})
        completed = subprocess.CompletedProcess([], 0, json.dumps(action), "")
        code, output, run = self.run_cli(["caffeine", "set", "indefinite", "--json"], completed)
        self.assertEqual(code, 0)
        self.assertEqual(output, action)
        self.assertEqual(run.call_args.args[0][1:], ["blox", "caffeine", "set", "indefinite"])

    def test_owner_absence_requires_specific_ipc_evidence(self):
        for returncode, expected in ((3, {"ownerAbsent": True}), (1, None), (2, None)):
            with self.subTest(returncode=returncode):
                completed = subprocess.CompletedProcess([], returncode, "", "")
                with patch.object(bloxctl.subprocess, "run", return_value=completed):
                    action = bloxctl.call_owner()
                self.assertEqual(action["code"], "unavailable")
                self.assertEqual(action["data"], expected)

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

    def settings_owner_replies(self, action):
        pending = bloxctl.result(True, "pending", "", {"requestId": "test-request"})
        return [
            subprocess.CompletedProcess(["ipc"], 0, json.dumps(pending), ""),
            subprocess.CompletedProcess(["ipc"], 0, json.dumps(action), ""),
        ]

    def test_settings_get_and_reset_use_the_running_settings_owner(self):
        for argv, operation, expected_request, expected_action in (
            (["settings", "get", "--json"], "get", {}, SETTINGS_RESULTS["get"]),
            (["settings", "reset", "bar", "--revision", "1", "--json"], "reset", {"section": "bar", "expectedRevision": 1}, SETTINGS_RESULTS["success"]),
        ):
            with self.subTest(operation=operation):
                code, output, run = self.run_cli(argv, self.settings_owner_replies(expected_action))
                self.assertEqual(code, 0)
                self.assertEqual(output, expected_action)
                first_command = run.call_args_list[0].args[0]
                self.assertEqual(first_command[1:4], ["settings", "begin", operation])
                self.assertEqual(json.loads(first_command[4]), expected_request)
                self.assertEqual(run.call_args_list[1].args[0][1:4], ["settings", "poll", "test-request"])

    def test_settings_cli_and_qml_share_success_conflict_and_validation_results(self):
        cases = (
            (["settings", "set", "bar.layout.position", '"right"', "--revision", "0", "--json"], "success", bloxctl.EXIT_OK),
            (["settings", "set", "bar.layout.position", '"left"', "--revision", "0", "--json"], "conflict", bloxctl.EXIT_CONFLICT),
            (["settings", "set", "bar.layout.position", '"diagonal"', "--revision", "1", "--json"], "validationFailure", bloxctl.EXIT_INVALID_DATA),
        )
        for argv, scenario, expected_exit in cases:
            with self.subTest(scenario=scenario):
                expected = SETTINGS_RESULTS[scenario]
                code, output, run = self.run_cli(argv, self.settings_owner_replies(expected))
                self.assertEqual(code, expected_exit)
                self.assertEqual(output, expected)
                self.assertEqual(output["data"]["revision"], expected["data"]["revision"])
                self.assertEqual(output["code"], expected["code"])
                self.assertEqual(output["data"]["changedComponents"], expected["data"]["changedComponents"])
                begin = run.call_args_list[0].args[0]
                self.assertEqual(begin[1:4], ["settings", "begin", "set"])
                request = json.loads(begin[4])
                self.assertEqual(request["path"], "bar.layout.position")
                self.assertEqual(request["valueJson"], argv[3])
                self.assertEqual(request["expectedRevision"], int(argv[5]))

    def test_theme_list_is_available_through_the_public_adapter(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict("os.environ", {"XDG_DATA_HOME": temporary}):
            code, output, _ = self.run_cli(["theme", "list", "--json"])
            self.assertEqual(code, 0)
            self.assertEqual(output["code"], "ok")
            self.assertTrue(any(item["id"] == "catppuccin-mocha" for item in output["data"]["themes"]))

    def test_theme_show_reports_resolved_values_and_redacts_home_paths(self):
        code, output, _ = self.run_cli(["theme", "show", "catppuccin-mocha", "--json"])
        self.assertEqual(code, 0)
        data = output["data"]
        self.assertEqual("catppuccin-mocha", data["id"])
        self.assertIn("resolved", data)
        self.assertNotIn(str(Path.home()), json.dumps(data))

    def test_theme_preview_is_data_only(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict("os.environ", {"XDG_STATE_HOME": temporary}):
            before = Path(temporary).exists() and sorted(Path(temporary).rglob("*"))
            code, output, _ = self.run_cli(["theme", "preview", "catppuccin-mocha", "--json"])
            self.assertEqual(code, 0)
            self.assertIn("changes", output["data"])
            self.assertEqual(before, sorted(Path(temporary).rglob("*")))

    def test_theme_apply_polls_the_loaded_settings_owner(self):
        receipt = bloxctl.result(True, "ok", data={"phase": "complete", "targets": {"gtk": {"state": "success"}}})
        with patch.object(bloxctl, "call_owner", side_effect=[bloxctl.result(True, "pending", data={"requestId": "r1"}), receipt]) as owner, patch.object(bloxctl, "_apply_backend") as backend:
            output = bloxctl._public_apply("apply", Path("/tmp/demo.json"), {"id": "demo"}, None, None)
        self.assertEqual(output, receipt)
        self.assertEqual(owner.call_args_list[0].args, ("begin", ["demo", "/tmp/demo.json"]))
        self.assertEqual(owner.call_args_list[1].kwargs, {"target": "settingsApply"})
        backend.assert_not_called()

    def test_theme_apply_does_not_bypass_owner_rejection(self):
        for code in ("busy", "conflict", "stale", "permission-denied", "timeout", "failed"):
            with self.subTest(code=code), patch.object(bloxctl, "call_owner", return_value=bloxctl.result(False, code)), patch.object(bloxctl, "_apply_backend") as backend:
                output = bloxctl._public_apply("apply", Path("/tmp/demo.json"), {"id": "demo"}, None, None)
                self.assertEqual(output["code"], code)
                backend.assert_not_called()

    def test_headless_apply_uses_shared_review_apply_and_finish(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict("os.environ", {"BLOX_HYPRLAND_PREVIEW_STATE": temporary + "/preview"}), patch.object(bloxctl, "call_owner", return_value=bloxctl.result(False, "unavailable", data={"ownerAbsent": True})), patch.object(bloxctl, "_apply_backend", side_effect=[bloxctl.result(True, "ok"), bloxctl.result(True, "ok", data={"scripts": [], "drift": None}), bloxctl.result(True, "ok", data={"phase": "complete"}), bloxctl.result(True, "ok")]) as backend:
            output = bloxctl._public_apply("apply", Path(temporary) / "demo.json", {"id": "demo"}, None, None)
        self.assertTrue(output["ok"])
        self.assertEqual([call.args[0] for call in backend.call_args_list], ["status", "review", "apply", "finish"])

    def test_headless_apply_refuses_retained_preview_or_journal(self):
        with tempfile.TemporaryDirectory() as temporary:
            preview = Path(temporary) / "preview"; preview.write_text("{}")
            with patch.dict("os.environ", {"BLOX_HYPRLAND_PREVIEW_STATE": str(preview)}), patch.object(bloxctl, "call_owner", return_value=bloxctl.result(False, "unavailable", data={"ownerAbsent": True})), patch.object(bloxctl, "_apply_backend") as backend:
                self.assertEqual(bloxctl._public_apply("apply", preview, {"id": "demo"}, None, None)["code"], "conflict")
                backend.assert_not_called()
            preview.unlink()
            with patch.dict("os.environ", {"BLOX_HYPRLAND_PREVIEW_STATE": str(preview)}), patch.object(bloxctl, "call_owner", return_value=bloxctl.result(False, "unavailable", data={"ownerAbsent": True})), patch.object(bloxctl, "_apply_backend", return_value=bloxctl.result(True, "ok", data={"phase": "partial"})) as backend:
                self.assertEqual(bloxctl._public_apply("apply", preview, {"id": "demo"}, None, None)["code"], "conflict")
                self.assertEqual(backend.call_count, 1)

    def test_theme_reset_routes_recorded_origin_through_shared_apply(self):
        core = SimpleNamespace(DEFAULT_THEME_ID="fallback")
        runtime = SimpleNamespace(RuntimeFailure=RuntimeError, current_generation=lambda: (Path("/tmp/current"), {"origin": {"theme_id": "origin"}}))
        load = Mock(return_value=(Path("/tmp/origin.json"), {}, {"id": "origin"}, None))
        with patch.object(bloxctl, "_theme_modules", return_value=(core, runtime)), patch.object(bloxctl, "_theme_load", load), patch.object(bloxctl, "_public_apply", return_value=bloxctl.result(True, "ok")) as apply:
            code, output = bloxctl.run_theme(SimpleNamespace(theme_command="reset"))
        self.assertEqual(code, 0)
        self.assertEqual(load.call_args.args[1], "origin")
        self.assertEqual(apply.call_args.args[2]["id"], "origin")

    def test_future_theme_schema_is_invalid_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "future.json"
            theme = json.loads((REPOSITORY / "themes/builtin/catppuccin-mocha.json").read_text(encoding="utf-8"))
            theme["schema_version"] = 99
            source.write_text(json.dumps(theme), encoding="utf-8")
            code, output, _ = self.run_cli(["theme", "show", str(source), "--json"])
            self.assertEqual(code, bloxctl.EXIT_INVALID_DATA)
            self.assertEqual(output["code"], "invalid-data")

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
