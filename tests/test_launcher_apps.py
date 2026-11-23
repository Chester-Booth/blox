import importlib.util
import json
import os
import re
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
ASSIGN_WORKSPACE_MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/assign_workspace.py"
COMMAND_EXEC_MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/command_exec.py"
DESKTOP_EXEC_PROBE = """
import shlex
import subprocess
import sys

sys.path.insert(0, str(%r))
from desktop_exec import GioUnix, resolve_command

entry = GioUnix.DesktopAppInfo.new("blox-settings.desktop")
assert entry is not None, "desktop entry was not resolved"
command, working_directory = resolve_command("blox-settings")
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
ASSIGN_WORKSPACE_SPEC = importlib.util.spec_from_file_location("assign_workspace", ASSIGN_WORKSPACE_MODULE)
assign_workspace = importlib.util.module_from_spec(ASSIGN_WORKSPACE_SPEC)
ASSIGN_WORKSPACE_SPEC.loader.exec_module(assign_workspace)
sys.path.insert(0, str(DESKTOP_EXEC_MODULE.parent))
COMMAND_EXEC_SPEC = importlib.util.spec_from_file_location("command_exec", COMMAND_EXEC_MODULE)
command_exec = importlib.util.module_from_spec(COMMAND_EXEC_SPEC)
COMMAND_EXEC_SPEC.loader.exec_module(command_exec)


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
    def test_workspace_launch_uses_a_silent_hyprland_exec_rule(self, popen, run):
        run.return_value.returncode = 0
        environment = {
            "WAYLAND_DISPLAY": "wayland-1",
            "XCURSOR_THEME": "blox-generated",
            "XCURSOR_SIZE": "24",
        }

        self.assertEqual(
            0,
            desktop_exec.launch_detached(
                ["example-app", "two words"],
                "/tmp/work files",
                environment,
                "example-app.desktop",
                3,
                "request-1",
            ),
        )

        popen.assert_not_called()
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["hyprctl", "eval"])
        self.assertIn("hl.dispatch(hl.dsp.exec_cmd(", command[2])
        self.assertIn('workspace = "3 silent"', command[2])
        self.assertIn("BLOX_LAUNCH_ID=request-1", command[2])
        self.assertIn("BLOX_LAUNCH_WORKSPACE=3", command[2])
        self.assertIn("XCURSOR_THEME=blox-generated", command[2])
        self.assertIn("cd -- '/tmp/work files'", command[2])
        self.assertIn("'two words'", command[2])
        startup_rule = run.call_args_list[0].args[0][2]
        self.assertIn("hl.window_rule(", startup_rule)
        self.assertIn("old.rule:set_enabled(false)", startup_rule)
        self.assertIn("timer:set_enabled(false)", startup_rule)
        self.assertIn("timeout=60000", startup_rule)

    def test_workspace_launch_finds_user_bin_with_compositor_system_path(self):
        with tempfile.TemporaryDirectory(prefix="blox-launch-path-") as temporary:
            user_bin = Path(temporary) / "user bin"
            user_bin.mkdir()
            executable = user_bin / "blox-settings-ipc"
            executable.write_text("#!/bin/sh\nprintf '%s' \"$1\"\n")
            executable.chmod(0o755)
            command = desktop_exec._workspace_command(
                ["blox-settings-ipc", "settingsUi"], None,
                {"PATH": f"{user_bin}:/usr/bin"}, 3, "path-proof",
            )
            result = subprocess.run(
                ["/bin/sh", "-c", command], env={"PATH": "/usr/bin"},
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(result.stdout, "settingsUi")

    @mock.patch.object(desktop_exec.subprocess, "run")
    @mock.patch.object(desktop_exec.subprocess, "Popen")
    def test_workspace_rule_failure_never_launches_an_unplaced_second_process(self, popen, run):
        run.return_value.returncode = 1
        popen.return_value.pid = 1234

        self.assertEqual(
            1,
            desktop_exec.launch_detached(
                ["example-app"], None, {}, "example-app.desktop", 3, "request-2"
            ),
        )

        popen.assert_not_called()

    @mock.patch.object(desktop_exec.subprocess, "run")
    @mock.patch.object(desktop_exec.subprocess, "Popen")
    def test_workspace_timeout_does_not_duplicate_an_uncertain_launch(self, popen, run):
        run.side_effect = subprocess.TimeoutExpired(["hyprctl"], 5)
        with self.assertRaises(subprocess.TimeoutExpired):
            desktop_exec.launch_detached(["example-app"], None, {}, workspace_id=3,
                                         launch_id="widget-test", timeout_seconds=5)
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        run.assert_called_once()
        popen.assert_not_called()

    @mock.patch.object(desktop_exec.subprocess, "run")
    @mock.patch.object(desktop_exec.subprocess, "Popen")
    def test_t3code_launcher_uses_a_transient_user_service(self, popen, run):
        run.return_value.returncode = 0
        environment = {
            "WAYLAND_DISPLAY": "wayland-1",
            "XDG_SESSION_TYPE": "wayland",
            "XCURSOR_THEME": "blox-generated",
            "ELECTRON_RUN_AS_NODE": "1",
        }

        self.assertEqual(
            0,
            desktop_exec.launch_detached(
                ["t3code-nightly"], "/tmp", environment, "t3code.desktop", 3, "request-t3"
            ),
        )

        popen.assert_not_called()
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["systemd-run", "--user", "--collect", "--no-block", "--quiet"])
        self.assertTrue(any(argument.startswith("--unit=blox-desktop-t3code-") for argument in command))
        self.assertIn("--working-directory=/tmp", command)
        self.assertIn("--setenv=XDG_SESSION_TYPE=wayland", command)
        self.assertIn("--setenv=XCURSOR_THEME=blox-generated", command)
        self.assertIn("--setenv=BLOX_LAUNCH_ID=request-t3", command)
        self.assertIn("--setenv=BLOX_LAUNCH_WORKSPACE=3", command)
        self.assertNotIn("--setenv=ELECTRON_RUN_AS_NODE=1", command)
        self.assertEqual(command[-2:], ["--", "t3code-nightly"])
        self.assertEqual(str(Path("/tmp")), run.call_args.kwargs["cwd"])

    @mock.patch.object(desktop_exec.subprocess, "run")
    @mock.patch.object(desktop_exec.subprocess, "Popen")
    def test_obsidian_launcher_uses_a_transient_user_service(self, popen, run):
        run.return_value.returncode = 0
        environment = {"WAYLAND_DISPLAY": "wayland-1", "XDG_SESSION_TYPE": "wayland"}

        self.assertEqual(
            0,
            desktop_exec.launch_detached(
                ["/usr/bin/obsidian"], None, environment, "obsidian.desktop"
            ),
        )

        popen.assert_not_called()
        command = run.call_args.args[0]
        self.assertEqual(
            command[:5], ["systemd-run", "--user", "--collect", "--no-block", "--quiet"]
        )
        self.assertTrue(
            any(argument.startswith("--unit=blox-desktop-obsidian-") for argument in command)
        )
        self.assertIn("--setenv=WAYLAND_DISPLAY=wayland-1", command)
        self.assertEqual(command[-2:], ["--", "/usr/bin/obsidian"])

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
        (fake_bin / "blox-settings-ipc").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (fake_bin / "blox-settings-ipc").chmod(0o755)
        probe_env = {**os.environ, "XDG_DATA_HOME": str(data_home), "PATH": f"{fake_bin}:{os.environ['PATH']}"}
        probe = subprocess.run(
            [sys.executable, "-c", DESKTOP_EXEC_PROBE],
            env=probe_env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, probe.returncode, (probe.stderr or "") + (probe.stdout or ""))

    def test_launcher_retains_startup_context_for_later_windows(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        method = re.search(r"function handleHyprlandEvent\(event\) \{(.*?)^    \}", source, re.M | re.S)
        probe = r"""
const assert = require('node:assert/strict');
const vm = require('node:vm');
const body = JSON.parse(require('node:fs').readFileSync(0, 'utf8')).body;
const now = Date.now();
const context = {workspaceTransfers: [{launchId:'request-1', workspaceId:3, startedAt:now, expiresAt:now+300000}]};
vm.runInNewContext('function handle(event) {' + body + '}', context);
context.handle({name:'custom',data:'blox_launch_workspace_assigned>>request-1'});
assert.equal(context.workspaceTransfers.length,1);
assert.ok(context.workspaceTransfers[0].expiresAt >= now+14000);
assert.ok(context.workspaceTransfers[0].expiresAt <= now+16000);
context.workspaceTransfers[0].startedAt=now-299000;
context.handle({name:'custom',data:'blox_launch_workspace_assigned>>request-1'});
assert.equal(context.workspaceTransfers[0].expiresAt,now+1000);
"""
        result = subprocess.run(["node", "-e", probe], input=json.dumps({"body":method.group(1)}),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_launcher_normalises_hyprland_window_addresses(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        method = re.search(
            r"function handleHyprlandEvent\(event\) \{(.*?)^    \}",
            source,
            re.M | re.S,
        )
        self.assertIsNotNone(method)
        probe = r"""
const assert = require('node:assert/strict');
const request = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const calls = [];
const transfers = [{launchId: 'request-1', workspaceId: 3}];
const quickshell = {shellDir: '/shell', execDetached(args) { calls.push(args); }};
const handle = new Function('event', 'workspaceTransfers', 'Quickshell', 'expireWorkspaceTransfers', request.body);
handle({name: 'openwindow', data: 'abc123,3,Example,Title'}, transfers, quickshell, () => {});
handle({name: 'openwindow', data: '0xdef456,3,Example,Title'}, transfers, quickshell, () => {});
handle({name: 'openwindow', data: 'not-an-address,3,Example,Title'}, transfers, quickshell, () => {});
assert.equal(calls.length, 2);
assert.equal(calls[0][2], '0xabc123');
assert.equal(calls[1][2], '0xdef456');
assert.deepEqual(JSON.parse(calls[0][3]), [{launchId: 'request-1', workspaceId: 3}]);
"""
        completed = subprocess.run(
            ["node", "-e", probe],
            input=json.dumps({"body": method.group(1)}),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_launcher_theme_activation_uses_shared_owner_and_preserves_busy_guard(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        method = re.search(r"function applyTheme\(entry\) \{(.*?)^    \}", source, re.M | re.S)
        self.assertIsNotNone(method)
        probe = r"""
const assert = require('node:assert/strict');
const request = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const calls = [];
let signals = 0;
const owner = {busy: false, quickApply(entry) { calls.push(entry); }};
const activate = new Function('SettingsApplyController', 'themeApplyStarted', 'entry', request.body);
function apply(entry) { activate(owner, () => signals++, entry); }
apply(null);
apply({name: 'No source'});
assert.equal(calls.length, 0);
assert.equal(signals, 0);
owner.busy = true;
apply(request.entry);
assert.equal(calls.length, 0);
assert.equal(signals, 0);
owner.busy = false;
apply(request.entry);
assert.deepEqual(calls, [request.entry]);
assert.equal(signals, 1);
"""
        completed = subprocess.run(
            ["node", "-e", probe],
            input=json.dumps({"body": method.group(1), "entry": {"id": "catppuccin-mocha", "name": "Mocha", "preview": {"widget_count": 2}}}),
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

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

    def test_terminal_command_uses_the_workspace_aware_launcher(self):
        argv = ["command_exec.py", "3", "request-terminal", "/tmp/project", "top", "-b"]
        with mock.patch.object(command_exec.sys, "argv", argv), mock.patch.object(
            command_exec, "active_cursor_environment", return_value={}
        ), mock.patch.object(command_exec, "launch_detached", return_value=0) as launch:
            self.assertEqual(0, command_exec.main())

        command, working_directory = launch.call_args.args[:2]
        self.assertEqual(
            ["kitty", "--directory", "/tmp/project", "--", "top", "-b"], command
        )
        self.assertEqual("/tmp/project", working_directory)
        self.assertEqual(3, launch.call_args.kwargs["workspace_id"])
        self.assertEqual("request-terminal", launch.call_args.kwargs["launch_id"])

    def test_open_window_moves_only_when_launch_id_matches(self):
        root = Path(tempfile.mkdtemp(prefix="blox-launch-environment-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        process = root / "4242"
        process.mkdir()
        (process / "environ").write_bytes(
            b"BLOX_LAUNCH_ID=request-3\0BLOX_LAUNCH_WORKSPACE=3\0"
        )
        commands = []

        def run(command, **_kwargs):
            commands.append(command)
            if command[1:3] == ["clients", "-j"]:
                return subprocess.CompletedProcess(
                    command,
                    0,
                    json.dumps([{"address": "0xabc", "pid": 4242, "workspace": {"id": 1}}]),
                    "",
                )
            return subprocess.CompletedProcess(command, 0, "", "")

        moved = assign_workspace.assign_workspace(
            "0xabc",
            [{"launchId": "request-3", "workspaceId": 3}],
            proc_root=root,
            run=run,
        )

        self.assertTrue(moved)
        self.assertEqual(["hyprctl", "eval"], commands[1][:2])
        self.assertIn("hl.dispatch(hl.dsp.window.move({", commands[1][2])
        self.assertIn('workspace = 3, window = "address:0xabc", follow = false', commands[1][2])
        self.assertEqual(["hyprctl", "eval"], commands[2][:2])
        self.assertIn("hl.dispatch(hl.dsp.event(", commands[2][2])
        self.assertIn("blox_launch_workspace_assigned>>request-3", commands[2][2])

    def test_sandboxed_startup_windows_match_one_pending_desktop(self):
        client = {"address": "0xabc", "pid": 4242, "class": "org.example.App",
                  "workspace": {"id": 4}}
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 0,
                json.dumps([client]) if command[1:3] == ["clients", "-j"] else "", "")
        context = {"launchId": "request-1", "workspaceId": 3,
                   "desktopId": "org.example.App", "existingAddresses": []}
        with mock.patch.object(assign_workspace, "_environment_for", return_value={}):
            for address in ["0xabc", "0xdef"]:
                client["address"] = address
                self.assertTrue(assign_workspace.assign_workspace(address, [context], run=run))
            self.assertFalse(assign_workspace.assign_workspace("0xdef",
                [{**context, "existingAddresses": ["0xdef"]}], run=run))
            self.assertFalse(assign_workspace.assign_workspace("0xdef",
                [context, {**context, "launchId": "request-2"}], run=run))
            for tags in [{b"BLOX_LAUNCH_ID": b"other", b"BLOX_LAUNCH_WORKSPACE": b"3"},
                         {b"BLOX_LAUNCH_ID": b"request-1", b"BLOX_LAUNCH_WORKSPACE": b"4"}]:
                with mock.patch.object(assign_workspace, "_environment_for", return_value=tags):
                    self.assertFalse(assign_workspace.assign_workspace("0xdef", [context], run=run))
            client["class"] = "unrelated"
            self.assertFalse(assign_workspace.assign_workspace("0xdef", [context], run=run))

    def test_open_window_with_an_untracked_launch_is_left_alone(self):
        root = Path(tempfile.mkdtemp(prefix="blox-launch-environment-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        process = root / "4242"
        process.mkdir()
        (process / "environ").write_bytes(
            b"BLOX_LAUNCH_ID=other\0BLOX_LAUNCH_WORKSPACE=3\0"
        )
        commands = []

        def run(command, **_kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(
                command,
                0,
                json.dumps([{"address": "0xabc", "pid": 4242, "workspace": {"id": 1}}]),
                "",
            )

        moved = assign_workspace.assign_workspace(
            "0xabc",
            [{"launchId": "request-3", "workspaceId": 3}],
            proc_root=root,
            run=run,
        )

        self.assertFalse(moved)
        self.assertEqual(1, len(commands))

    def test_normalise_ignores_case_and_desktop_suffix(self):
        self.assertEqual("org.example.app", appctl.normalise("Org.Example.App.desktop"))

    @mock.patch.object(appctl.subprocess, "run")
    @mock.patch.object(appctl.subprocess, "check_output")
    def test_focuses_the_most_recent_matching_window(self, check_output, run):
        check_output.return_value = json.dumps([
            {"address": "0xabc", "class": "Example", "initialClass": "", "focusHistoryID": 8},
            {"address": "0xdef", "class": "other", "initialClass": "example.desktop", "focusHistoryID": 0},
        ]).encode()
        run.return_value.returncode = 0
        with mock.patch.object(appctl.sys, "argv", ["appctl.py", "Example.desktop"]):
            self.assertEqual(0, appctl.main())
        self.assertEqual(["hyprctl", "eval"], run.call_args.args[0][:2])
        self.assertIn('hl.dispatch(hl.dsp.focus({window="address:0xdef"}))', run.call_args.args[0][-1])

    @mock.patch.object(appctl.subprocess, "check_output", return_value=b"[]")
    def test_returns_three_when_the_app_is_not_running(self, _check_output):
        with mock.patch.object(appctl.sys, "argv", ["appctl.py", "missing"]):
            self.assertEqual(3, appctl.main())


if __name__ == "__main__":
    unittest.main()
