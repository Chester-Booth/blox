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
    @mock.patch.object(desktop_exec.subprocess, "run")
    @mock.patch.object(desktop_exec.subprocess, "Popen")
    @mock.patch.object(desktop_exec, "resolve_command", return_value=(["code"], None))
    @mock.patch.object(desktop_exec.sys, "argv", ["desktop_exec.py", "code.desktop"])
    def test_desktop_launcher_detaches_without_a_transient_systemd_scope(self, _resolve, popen, run):
        popen.return_value.pid = 1234
        self.assertEqual(0, desktop_exec.main())
        run.assert_not_called()
        self.assertEqual(["code"], popen.call_args.args[0])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    @mock.patch.object(desktop_exec.subprocess, "Popen")
    def test_launch_detached_preserves_the_working_directory_and_environment(self, popen):
        popen.return_value.pid = 1234
        environment = {"WAYLAND_DISPLAY": "wayland-1", "XCURSOR_THEME": "blox-generated"}
        self.assertEqual(0, desktop_exec.launch_detached(["thunar"], "~/Documents", environment))
        self.assertEqual(["thunar"], popen.call_args.args[0])
        self.assertEqual(str(Path.home() / "Documents"), popen.call_args.kwargs["cwd"])
        self.assertEqual(environment, popen.call_args.kwargs["env"])
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    @mock.patch.object(desktop_exec.subprocess, "run")
    @mock.patch.object(desktop_exec.subprocess, "Popen")
    def test_t3code_launcher_uses_a_transient_user_service(self, popen, run):
        run.return_value.returncode = 0
        environment = {
            "WAYLAND_DISPLAY": "wayland-1",
            "XCURSOR_THEME": "blox-generated",
            "ELECTRON_RUN_AS_NODE": "1",
        }

        self.assertEqual(
            0,
            desktop_exec.launch_detached(
                ["t3code-nightly"], "/tmp", environment, "t3code.desktop"
            ),
        )

        popen.assert_not_called()
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["systemd-run", "--user", "--collect", "--no-block", "--quiet"])
        self.assertTrue(any(argument.startswith("--unit=blox-desktop-t3code-") for argument in command))
        self.assertIn("--working-directory=/tmp", command)
        self.assertIn("--setenv=XCURSOR_THEME=blox-generated", command)
        self.assertNotIn("--setenv=ELECTRON_RUN_AS_NODE=1", command)
        self.assertEqual(command[-2:], ["--", "t3code-nightly"])
        self.assertEqual(str(Path("/tmp")), run.call_args.kwargs["cwd"])

    def test_helium_launcher_loads_the_active_blox_theme(self):
        root = Path(tempfile.mkdtemp(prefix="blox-helium-launcher-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        state = root / "state"
        theme = state / "blox/theme/current/helium"
        theme.mkdir(parents=True)
        (theme / "manifest.json").write_text("{}\n", encoding="utf-8")
        browser = root / "browser"
        browser.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
        browser.chmod(0o755)

        result = subprocess.run(
            [str(REPOSITORY / "bin/blox-helium-browser"), "https://example.test"],
            env={**os.environ, "XDG_STATE_HOME": str(state), "BLOX_HELIUM_BINARY": str(browser)},
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["--ozone-platform=wayland", f"--load-extension={theme}", "https://example.test"],
            result.stdout.splitlines(),
        )

    def test_helium_launcher_preserves_normal_start_without_a_theme(self):
        root = Path(tempfile.mkdtemp(prefix="blox-helium-fallback-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        browser = root / "browser"
        browser.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
        browser.chmod(0o755)

        result = subprocess.run(
            [str(REPOSITORY / "bin/blox-helium-browser"), "--incognito"],
            env={**os.environ, "XDG_STATE_HOME": str(root / "state"), "BLOX_HELIUM_BINARY": str(browser)},
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["--ozone-platform=wayland", "--incognito"], result.stdout.splitlines())

    def test_helium_launcher_passes_the_active_cursor_to_new_processes(self):
        root = Path(tempfile.mkdtemp(prefix="blox-helium-cursor-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        state = root / "state"
        metadata = state / "blox/theme/current/cursor/metadata.json"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(
            json.dumps({"theme_name": "blox-generated", "size": 22, "format": "xcursor+hyprcursor-v1"}),
            encoding="utf-8",
        )
        browser = root / "browser"
        browser.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$XCURSOR_THEME\" \"$XCURSOR_SIZE\" \"$XCURSOR_PATH\" \"$HYPRCURSOR_THEME\" \"$HYPRCURSOR_SIZE\"\n",
            encoding="utf-8",
        )
        browser.chmod(0o755)

        result = subprocess.run(
            [str(REPOSITORY / "bin/blox-helium-browser"), "https://example.test"],
            env={
                **os.environ,
                "XDG_STATE_HOME": str(state),
                "BLOX_HELIUM_BINARY": str(browser),
                "XCURSOR_THEME": "Bibata-Modern-Classic",
                "XCURSOR_SIZE": "20",
                "HYPRCURSOR_SIZE": "20",
            },
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            [
                "blox-generated",
                "22",
                f"{Path.home() / '.local/share' / 'icons'}:{Path.home() / '.icons'}:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps",
                "blox-generated",
                "22",
            ],
            result.stdout.splitlines(),
        )

    def test_helium_launcher_preserves_an_explicit_ozone_platform(self):
        root = Path(tempfile.mkdtemp(prefix="blox-helium-ozone-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        browser = root / "browser"
        browser.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
        browser.chmod(0o755)

        result = subprocess.run(
            [str(REPOSITORY / "bin/blox-helium-browser"), "--ozone-platform=x11", "--incognito"],
            env={**os.environ, "XDG_STATE_HOME": str(root / "state"), "BLOX_HELIUM_BINARY": str(browser)},
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["--ozone-platform=x11", "--incognito"], result.stdout.splitlines())

    def test_chromium_launcher_loads_the_active_blox_theme(self):
        root = Path(tempfile.mkdtemp(prefix="blox-chromium-launcher-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        state = root / "state"
        theme = state / "blox/theme/current/chromium"
        theme.mkdir(parents=True)
        (theme / "manifest.json").write_text("{}\n", encoding="utf-8")
        browser = root / "browser"
        browser.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n", encoding="utf-8")
        browser.chmod(0o755)

        result = subprocess.run(
            [str(REPOSITORY / "bin/blox-chromium-browser"), "https://example.test"],
            env={**os.environ, "XDG_STATE_HOME": str(state), "BLOX_CHROMIUM_BINARY": str(browser)},
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["--ozone-platform=wayland", f"--load-extension={theme}", "https://example.test"],
            result.stdout.splitlines(),
        )

    def test_chromium_launcher_fails_clearly_without_a_browser(self):
        root = Path(tempfile.mkdtemp(prefix="blox-chromium-missing-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        path = root / "bin"
        path.mkdir()

        result = subprocess.run(
            ["/usr/bin/bash", str(REPOSITORY / "bin/blox-chromium-browser")],
            # Keep host browser packages out of this absence test. The
            # launcher must report the missing-browser contract, not try to
            # start whatever the runner happens to have installed. Invoke
            # Bash directly because the launcher shebang uses env from PATH.
            env={**os.environ, "PATH": str(path), "XDG_STATE_HOME": str(root / "state")},
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(127, result.returncode)
        self.assertIn("Chromium is not installed", result.stderr)

    def test_helium_desktop_entry_uses_the_blox_launcher(self):
        entry = (REPOSITORY / "applications/.local/share/applications/helium.desktop").read_text(encoding="utf-8")
        self.assertIn("Exec=blox-helium-browser %U", entry)
        self.assertIn("Exec=blox-helium-browser --incognito", entry)

    def test_chromium_desktop_entry_uses_the_blox_launcher(self):
        entry = (REPOSITORY / "applications/.local/share/applications/chromium.desktop").read_text(encoding="utf-8")
        self.assertIn("TryExec=chromium", entry)
        self.assertIn("Exec=blox-chromium-browser %U", entry)
        self.assertIn("Exec=blox-chromium-browser --incognito", entry)

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
        # gio resolves the Exec binary while building the entry; provide the
        # shipped IPC passthrough exactly as an installed system would.
        fake_bin = data_home / "bin"
        fake_bin.mkdir()
        (fake_bin / "blox-theme-ipc").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (fake_bin / "blox-theme-ipc").chmod(0o755)
        probe_env = {**os.environ, "XDG_DATA_HOME": str(data_home), "PATH": f"{fake_bin}:{os.environ['PATH']}"}
        probe = subprocess.run(
            [sys.executable, "-c", DESKTOP_EXEC_PROBE],
            env=probe_env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, probe.returncode, (probe.stderr or "") + (probe.stdout or ""))

    def test_launcher_accepts_a_successful_apply_with_warnings(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn("response.ok === true && response.data && response.data.theme_id", source)
        self.assertNotIn("(exitCode === 0 || exitCode === 10) && response.data", source)

    def test_active_cursor_environment_uses_the_current_generation(self):
        state = Path(tempfile.mkdtemp(prefix="blox-desktop-cursor-"))
        self.addCleanup(shutil.rmtree, state, ignore_errors=True)
        metadata = state / "blox/theme/current/cursor/metadata.json"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(
            json.dumps({"theme_name": "blox-generated", "size": 22, "format": "xcursor+hyprcursor-v1"}),
            encoding="utf-8",
        )
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": str(state)}, clear=False):
            self.assertEqual(
                {
                    "XCURSOR_THEME": "blox-generated",
                    "XCURSOR_SIZE": "22",
                    "XCURSOR_PATH": f"{Path.home() / '.local/share' / 'icons'}:{Path.home() / '.icons'}:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps",
                    "HYPRCURSOR_THEME": "blox-generated",
                    "HYPRCURSOR_SIZE": "22",
                },
                desktop_exec.active_cursor_environment(),
            )

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
