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

    def test_theme_list_is_available_through_the_public_adapter(self):
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

    def test_theme_apply_uses_the_authoritative_target_set(self):
        theme = {"id": "demo", "targets": {"quickshell": True}}
        validation = SimpleNamespace(errors=[], warnings=["restart required"])
        apply = Mock(return_value=({
            "generation_id": "20260901T120000Z-12345678",
            "theme_id": "demo",
            "enabled_targets": ["quickshell"],
        }, ["follow-up"]))
        core = SimpleNamespace(
            validate_theme=lambda *args, **kwargs: validation,
        )
        runtime = SimpleNamespace(
            TARGET_NAMES=("quickshell", "wallpaper"),
            RuntimeFailure=RuntimeError,
            LockContended=RuntimeError,
            configured_targets=lambda value: ("quickshell",),
            apply_theme=apply,
        )
        args = SimpleNamespace(theme_command="apply", theme="demo")
        with patch.object(bloxctl, "_theme_modules", return_value=(core, runtime)), patch.object(
            bloxctl,
            "_theme_load",
            return_value=(Path("/tmp/demo.json"), {}, theme, None),
        ):
            code, output = bloxctl.run_theme(args)

        self.assertEqual(code, 0)
        self.assertTrue(output["ok"])
        self.assertEqual(apply.call_args.args[2], runtime.TARGET_NAMES)
        self.assertTrue(apply.call_args.kwargs["authoritative_targets"])
        self.assertIn("follow-up", output["data"]["warnings"])

    def test_theme_reset_uses_recorded_origin(self):
        theme = {"id": "catppuccin-mocha", "targets": {"quickshell": True}}
        validation = SimpleNamespace(errors=[], warnings=[])
        apply = Mock(return_value=({
            "generation_id": "20260901T120000Z-12345678",
            "theme_id": "catppuccin-mocha",
            "enabled_targets": ["quickshell"],
        }, []))
        core = SimpleNamespace(
            DEFAULT_THEME_ID="catppuccin-frappe",
            validate_theme=lambda *args, **kwargs: validation,
        )
        runtime = SimpleNamespace(
            TARGET_NAMES=("quickshell",),
            RuntimeFailure=RuntimeError,
            LockContended=RuntimeError,
            current_generation=lambda: (Path("/tmp/current"), {"origin": {"kind": "builtin", "theme_id": "catppuccin-mocha", "fallback": False}}),
            configured_targets=lambda value: ("quickshell",),
            apply_theme=apply,
        )
        load = Mock(return_value=(Path("/tmp/catppuccin-mocha.json"), {}, theme, None))
        args = SimpleNamespace(theme_command="reset")
        with patch.object(bloxctl, "_theme_modules", return_value=(core, runtime)), patch.object(bloxctl, "_theme_load", load):
            code, output = bloxctl.run_theme(args)

        self.assertEqual(code, 0)
        self.assertTrue(output["ok"])
        self.assertEqual(load.call_args.args[1], "catppuccin-mocha")
        self.assertEqual(output["data"]["theme_id"], "catppuccin-mocha")

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
