"""Compatibility clients preserve owner rejection without a native fallback."""
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class ControlRoutingTests(unittest.TestCase):
    def test_multimedia_keybind_and_popout_scripts_preserve_owner_denial(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            owner = directory / "quickshell"
            owner.write_text('#!/bin/sh\nprintf \'{"version":1,"ok":false,"code":"permission-denied","message":"blocked","data":null}\\n\'\n')
            owner.chmod(0o755)
            marker = directory / "native-mutation"
            for command in ("pactl", "brightnessctl", "hyprctl", "asusctl"):
                helper = directory / command
                helper.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 99\n')
                helper.chmod(0o755)
            fixture = directory / "package"
            for relative in ("osd/control.sh", "control.sh", "display/hyprsunset-toggle.sh", "bloxctl.py", "ipc.sh"):
                target = fixture / "shell/scripts" / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / "shell/scripts" / relative, target)
            environment = dict(os.environ, PATH=str(directory) + ":" + os.environ["PATH"], QUICKSHELL_IPC_PID="4242")
            for script, arguments in (("osd/control.sh", ["volume-up", "2"]), ("osd/control.sh", ["brightness-down", "2"]), ("osd/control.sh", ["touchpad-toggle"]), ("control.sh", ["audio-toggle"]), ("display/hyprsunset-toggle.sh", [])):
                with self.subTest(script=script, arguments=arguments):
                    reply = subprocess.run([str(fixture / "shell/scripts" / script), *arguments], env=environment, capture_output=True, text=True)
                    self.assertEqual(reply.returncode, 4, reply.stderr)
                    self.assertEqual(json.loads(reply.stdout)["code"], "permission-denied")
                    self.assertFalse(marker.exists())

    def test_night_light_status_distinguishes_identity_and_scheduled_filter(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            cache = directory / "cache/quickshell"; cache.mkdir(parents=True)
            for command, source in (("pgrep", "exit 0"), ("hyprsunset", "exit 0"), ("date", "echo 12:00")):
                helper = directory / command
                helper.write_text("#!/bin/sh\n" + source + "\n"); helper.chmod(0o755)
            environment = dict(os.environ, XDG_CACHE_HOME=str(directory / "cache"), PATH=str(directory) + ":" + os.environ["PATH"])
            script = ROOT / "shell/scripts/providers/night-light.sh"
            def status():
                reply = subprocess.run([str(script), "status"], env=environment, capture_output=True, text=True, check=True)
                return json.loads(reply.stdout)
            (cache / "blue-light-mode").write_text("off\n")
            self.assertFalse(status()["active"])
            (cache / "blue-light-mode").write_text("on\n")
            self.assertTrue(status()["active"])
            (cache / "blue-light-mode").write_text("auto\n")
            config = cache / "hyprsunset/hypr/hyprsunset.conf"; config.parent.mkdir(parents=True)
            config.write_text("profile {\n time = 07:00\n identity = true\n}\nprofile {\n time = 20:00\n temperature = 4500\n}\n")
            self.assertFalse(status()["active"])
            (directory / "date").write_text("#!/bin/sh\necho 23:00\n")
            self.assertTrue(status()["active"])

    def test_night_light_restore_is_quiet_but_user_change_notifies(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            script = directory / "scripts/providers/night-light.sh"
            script.parent.mkdir(parents=True)
            script.write_bytes((ROOT / "shell/scripts/providers/night-light.sh").read_bytes())
            (directory / "scripts/display").mkdir()
            osd = directory / "scripts/osd/blue-light.sh"
            osd.parent.mkdir()
            marker = directory / "osd"
            osd.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$OSD_MARKER"\n')
            osd.chmod(0o755)
            commands = directory / "bin"
            commands.mkdir()
            for name, status in (("pgrep", 1), ("pkill", 1), ("hyprsunset", 0)):
                helper = commands / name
                helper.write_text(f"#!/bin/sh\nexit {status}\n")
                helper.chmod(0o755)
            environment = dict(os.environ, PATH=str(commands) + ":" + os.environ["PATH"],
                               XDG_CACHE_HOME=str(directory / "cache"),
                               XDG_CONFIG_HOME=str(directory / "config"), OSD_MARKER=str(marker))
            for mode in ("on", "off", "auto"):
                subprocess.run(["bash", str(script), mode, "--quiet"], env=environment, check=True)
                self.assertFalse(marker.exists())
            subprocess.run(["bash", str(script), "on"], env=environment, check=True)
            self.assertEqual(marker.read_text(), "on\n")
            self.assertEqual((directory / "cache/quickshell/blue-light-mode").read_text(), "on\n")

    def test_private_startup_replay_refuses_journal_before_runtime_mutation(self):
        path = ROOT / "shell/scripts/theme/runtime_maintenance.py"
        spec = importlib.util.spec_from_file_location("runtime_maintenance", path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"BLOX_HYPRLAND_PREVIEW_STATE": temporary + "/preview"}), patch.object(module.bloxctl, "_apply_backend", return_value=module.bloxctl.result(True, "ok", data={"phase": "partial"})), patch.object(module.runtime, "reconcile") as native:
            self.assertEqual(module.run()["code"], "conflict")
            native.assert_not_called()
