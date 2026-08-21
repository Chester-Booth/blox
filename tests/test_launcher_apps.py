import importlib.util
import json
import os
import shlex
import subprocess
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/appctl.py"
DESKTOP_EXEC_MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/desktop_exec.py"
ICON_LOOKUP_MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/icon_lookup.py"
DESKTOP_EXEC_PROBE = """
import shlex
import subprocess
import sys

sys.path.insert(0, str(%r))
from desktop_exec import GioUnix, resolve_command

entry = GioUnix.DesktopAppInfo.new("blox-theme-picker.desktop")
assert entry is not None, "desktop entry was not resolved"
command, working_directory = resolve_command("blox-theme-picker")
assert command == shlex.split(entry.get_string("Exec")), command
assert working_directory is None, working_directory
""" % str(DESKTOP_EXEC_MODULE.parent)

REPOSITORY = Path(__file__).parents[1]
LAUNCHER = Path(__file__).parents[1] / "shell/modules/LauncherMainController.qml"
SPEC = importlib.util.spec_from_file_location("appctl", MODULE)
appctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appctl)
DESKTOP_EXEC_SPEC = importlib.util.spec_from_file_location("desktop_exec", DESKTOP_EXEC_MODULE)
desktop_exec = importlib.util.module_from_spec(DESKTOP_EXEC_SPEC)
DESKTOP_EXEC_SPEC.loader.exec_module(desktop_exec)
ICON_LOOKUP_SPEC = importlib.util.spec_from_file_location("icon_lookup", ICON_LOOKUP_MODULE)
icon_lookup = importlib.util.module_from_spec(ICON_LOOKUP_SPEC)
ICON_LOOKUP_SPEC.loader.exec_module(icon_lookup)


class FakeIconFile:
    def __init__(self, path):
        self.path = path

    def get_path(self):
        return self.path


class FakeIcon:
    def __init__(self, path):
        self.path = path

    def get_file(self):
        return FakeIconFile(self.path)


class FakeIconTheme:
    def has_icon(self, name):
        return name == "new-app"

    def lookup_icon(self, name, *_args):
        return FakeIcon(f"/icons/{name}.svg")


class AppControllerTests(unittest.TestCase):
    def test_icon_lookup_returns_fresh_theme_paths(self):
        self.assertEqual(
            {"new-app": "/icons/new-app.svg"},
            icon_lookup.resolve_icons(["new-app", "missing", "new-app"], FakeIconTheme()),
        )

    def test_launcher_resolves_the_current_desktop_exec_when_activated(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('scripts/launcher/desktop_exec.py", desktopId];', source)
        self.assertIn("desktopLauncher.running = true;", source)
        self.assertIn("root.executeCurrentDesktopEntry(root.pendingEntry);", source)
        self.assertNotIn("root.pendingEntry.execute();", source)

        # Stage the shipped desktop entry into an isolated XDG data home so
        # the test does not depend on machine state. The child process loads
        # desktop_exec fresh against that environment.
        data_home = Path(tempfile.mkdtemp(prefix="blox-desktop-"))
        self.addCleanup(shutil.rmtree, data_home, ignore_errors=True)
        for area in ("applications", "icons"):
            shutil.copytree(
                REPOSITORY / "applications/.local/share" / area,
                data_home / area,
                dirs_exist_ok=True,
            )
        probe = subprocess.run(
            [sys.executable, "-c", DESKTOP_EXEC_PROBE],
            env={**os.environ, "XDG_DATA_HOME": str(data_home)},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, probe.returncode, probe.stderr or probe.stdout)

    def test_normalise_ignores_case_and_desktop_suffix(self):
        self.assertEqual("org.example.app", appctl.normalise("Org.Example.App.desktop"))

    @mock.patch.object(appctl.subprocess, "run")
    @mock.patch.object(appctl.subprocess, "check_output")
    def test_focuses_the_most_recent_matching_window(self, check_output, run):
        check_output.return_value = json.dumps([
            {"address": "0xold", "class": "Example", "initialClass": "", "focusHistoryID": 8},
            {"address": "0xnew", "class": "other", "initialClass": "example.desktop", "focusHistoryID": 0},
        ]).encode()
        run.return_value.returncode = 0
        with mock.patch.object(appctl.sys, "argv", ["appctl.py", "Example.desktop"]):
            self.assertEqual(0, appctl.main())
        self.assertEqual("address:0xnew", run.call_args.args[0][-1])

    @mock.patch.object(appctl.subprocess, "check_output", return_value=b"[]")
    def test_returns_three_when_the_app_is_not_running(self, _check_output):
        with mock.patch.object(appctl.sys, "argv", ["appctl.py", "missing"]):
            self.assertEqual(3, appctl.main())


if __name__ == "__main__":
    unittest.main()
