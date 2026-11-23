"""Offline first-party actions: temporary user data and injected external effects only."""
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("widget_user_actions", ROOT / "shell/scripts/widgets/user_actions.py")
actions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(actions)


class FakeRuntime:
    """No subprocess, compositor, network or application calls escape this fake."""
    def __init__(self):
        self.events = []
        self.elapsed = 0
        self.launch_id = None
        self.launch_code = 0
        self.window = None
        self.run_handler = lambda argv, timeout: subprocess.CompletedProcess(argv, 0, "", "")
        self.dispatch_error = None
        self.client_handler = None
        self.sleeps = []

    def clock(self):
        return self.elapsed

    def sleep(self, delay):
        self.elapsed += delay
        self.sleeps.append(delay)

    def now(self):
        return datetime(2026, 10, 24, 11, 30)

    def run(self, argv, timeout):
        self.events.append(("run", argv, timeout))
        return self.run_handler(argv, timeout)

    def launch(self, argv, workspace, launch_id):
        self.events.append(("launch", argv, workspace, launch_id))
        self.launch_id = launch_id
        if isinstance(self.launch_code, Exception):
            raise self.launch_code
        return self.launch_code

    def clients(self):
        self.events.append(("clients",))
        if self.client_handler:
            return self.client_handler()
        return [dict(self.window)] if self.launch_id and self.window else []

    def process_launch_id(self, pid):
        return self.launch_id if pid == 1234 else None

    def dispatch(self, expression):
        self.events.append(("dispatch", expression))
        if self.dispatch_error:
            raise self.dispatch_error
        if self.window:
            if "window.float" in expression:
                self.window["floating"] = True
            if "window.resize" in expression:
                import re
                self.window["size"] = list(map(int, re.search(r"x = (\d+), y = (\d+)", expression).groups()))
            if "window.move" in expression:
                self.window["at"] = [60, 20]


class UserActionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="blox-user-actions-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = {"HOME": str(self.root / "home"), "XDG_RUNTIME_DIR": str(self.root / "runtime"),
                            "XDG_STATE_HOME": str(self.root / "state"), "PATH": "",
                            actions.CONTEXT_ENV: '{"workspaceId":4}'}
        self.runtime = FakeRuntime()
        self.helper = actions.UserActions(self.environment, self.runtime)
        self.helper.todo.mkdir(parents=True)
        # Every test denies accidental real launches, even if a fake is bypassed.
        for name in ("Popen", "run"):
            guard = patch.object(subprocess, name, side_effect=AssertionError("Real process forbidden"))
            guard.start()
            self.addCleanup(guard.stop)

    def invoke(self, argv, runtime=None, environment=None):
        output = io.StringIO()
        code = actions.main(argv, self.environment if environment is None else environment,
                            self.runtime if runtime is None else runtime, output)
        return code, json.loads(output.getvalue())

    def write(self, name, text=""):
        path = self.helper.todo / name
        path.write_text(text, encoding="utf-8")
        return path

    def state(self, text, calendar=False):
        self.helper.state.mkdir(parents=True, exist_ok=True)
        path = self.helper.state / ("gcal-current" if calendar else "todo-current")
        path.write_text(text, encoding="utf-8")
        return path

    def micro(self):
        path = self.root / "micro with spaces"
        path.write_text("unused fake executable")
        path.chmod(0o700)
        self.environment["MICRO_BIN"] = str(path)
        self.helper.environment = dict(self.environment)
        return path

    def editor_window(self, **overrides):
        self.runtime.window = {"address": "0x123abc", "class": "quickshell_todo", "pid": 1234,
                               "workspace": {"id": 4}, "floating": False, "size": [100, 100], "at": [0, 0],
                               **overrides}

    def test_todo_missing_stale_wrap_and_exclusions(self):
        for name in ["c.md", "a.md", "b.md", *actions.CALENDAR_FILES, "ignore.txt"]:
            self.write(name)
        (self.helper.todo / "directory.md").mkdir()
        (self.helper.todo / "link.md").symlink_to(self.helper.todo / "a.md")
        expected = ["b.md", "c.md", "a.md"]
        for name in expected:
            code, reply = self.invoke(["todo", "next"])
            self.assertEqual(code, 0, reply)
            self.assertEqual(Path(reply["selectedFile"]).name, name)
            self.assertEqual((self.helper.state / "todo-current").read_text(), str(self.helper.todo / name) + "\n")
        self.state(str(self.helper.todo / "stale.md") + "\n")
        self.assertEqual(Path(self.invoke(["todo", "next"])[1]["selectedFile"]).name, "a.md")
        self.assertEqual(self.runtime.events, [])

    def test_empty_todo_returns_default_without_saving_selection(self):
        code, reply = self.invoke(["todo", "next"])
        self.assertEqual(code, 0)
        self.assertEqual(reply["selectedFile"], str(self.helper.todo / "1-todo.md"))
        self.assertFalse((self.helper.state / "todo-current").exists())
        state = self.state("stale\n")
        self.invoke(["todo", "next"])
        self.assertEqual(state.read_text(), "stale\n")

    def test_atomic_selection_is_complete_and_failed_replace_keeps_old_state(self):
        self.write("a.md")
        self.write("b.md")
        state = self.state(str(self.helper.todo / "a.md") + "\n")
        real_replace = os.replace
        observations = []
        def replace(source, destination):
            self.assertEqual(Path(source).parent, state.parent)
            observations.append((state.read_text(), Path(source).read_text()))
            real_replace(source, destination)
        with patch.object(actions.os, "replace", side_effect=replace):
            self.assertEqual(self.invoke(["todo", "next"])[0], 0)
        self.assertEqual(observations, [(str(self.helper.todo / "a.md") + "\n", str(self.helper.todo / "b.md") + "\n")])
        with patch.object(actions.os, "replace", side_effect=OSError("publish failed")):
            code, reply = self.invoke(["todo", "next"])
        self.assertEqual(code, 1)
        self.assertIn("publish failed", reply["message"])
        self.assertEqual(state.read_text(), str(self.helper.todo / "b.md") + "\n")
        self.assertEqual(list(state.parent.iterdir()), [state])

    def test_shared_lock_failure_is_bounded_and_does_not_write(self):
        self.write("a.md")
        self.helper.locks.mkdir(parents=True)
        with (self.helper.locks / "widget-todo.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, reply = self.invoke(["todo", "next"])
        self.assertEqual(code, 75)
        self.assertEqual(reply["code"], "busy")
        self.assertLessEqual(self.runtime.elapsed, 2.01)
        self.assertFalse((self.helper.state / "todo-current").exists())

    def test_calendar_fixed_cycle_releases_selection_lock_before_generation(self):
        selections = []
        def refresh(helper, generated):
            self.assertTrue(generated)
            with (helper.locks / "widget-gcal.lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            selections.append((helper.state / "gcal-current").read_text())
        with patch.object(actions.UserActions, "refresh", refresh):
            for name in ["80-today.md", "81-week.md", "99-gcal_week.md", "2-gcal.md"]:
                code, reply = self.invoke(["calendar", "next"])
                self.assertEqual(code, 0, reply)
                self.assertEqual(Path(reply["selectedFile"]).name, name)
            self.state("unknown\n", calendar=True)
            self.assertEqual(Path(self.invoke(["calendar", "next"])[1]["selectedFile"]).name, "2-gcal.md")
        self.assertEqual(len(selections), 5)

    def test_calendar_refresh_failure_keeps_new_selection_and_is_visible(self):
        with patch.object(actions.UserActions, "refresh", side_effect=actions.ActionError("fetch failed")):
            code, reply = self.invoke(["calendar", "next"])
        self.assertEqual(code, 1)
        self.assertIn("fetch failed", reply["message"])
        self.assertEqual((self.helper.state / "gcal-current").read_text(), str(self.helper.todo / "80-today.md") + "\n")

    def test_editor_literal_filename_micro_class_dimensions_and_exact_verified_window(self):
        micro = self.micro()
        selected = self.write('- a $(touch bad); "quote".md', "A" * 60 + "\nsecond\n\n")
        self.write("other.md")
        self.state(str(selected) + "\n")
        self.editor_window()
        code, reply = self.invoke(["todo", "edit"])
        self.assertEqual(code, 0, reply)
        launch = next(event for event in self.runtime.events if event[0] == "launch")
        self.assertEqual(launch[1], ["kitty", "--class", "quickshell_todo", "--title", "quickshell_todo", str(micro), str(selected)])
        self.assertEqual(launch[2], 4)
        self.assertTrue(launch[3].startswith("widget-action-"))
        self.assertEqual(self.runtime.window["size"], [580, 106])
        self.assertEqual(self.runtime.window["at"], [60, 20])
        dispatches = [event[1] for event in self.runtime.events if event[0] == "dispatch"]
        self.assertEqual(len(dispatches), 8)
        self.assertTrue(all('window = "address:0x123abc"' in event for event in dispatches))
        self.assertEqual(self.runtime.sleeps, [.15, .05])
        self.assertTrue(reply["launchAccepted"])
        self.assertTrue(reply["placementVerified"])

    def test_editor_default_creatable_file_and_content_heading_dimensions(self):
        self.micro()
        self.editor_window()
        code, reply = self.invoke(["todo", "edit"])
        self.assertEqual(code, 0, reply)
        self.assertEqual(self.runtime.window["size"], [200, 84])
        launch = next(event for event in self.runtime.events if event[0] == "launch")
        self.assertEqual(launch[1][-1], str(self.helper.todo / "1-todo.md"))
        self.assertFalse((self.helper.todo / "1-todo.md").exists())
        self.write("1-todo.md", "\n\n")
        self.assertEqual(self.helper.editor_dimensions(self.helper.todo / "1-todo.md"), (200, 80))

    def test_micro_executable_preference_and_path_fallback(self):
        micro = self.micro()
        self.editor_window()
        with patch.object(actions.shutil, "which", side_effect=AssertionError("Should prefer MICRO_BIN")):
            self.assertEqual(self.invoke(["todo", "edit"])[0], 0)
        self.runtime = FakeRuntime()
        self.editor_window()
        self.environment["MICRO_BIN"] = str(self.root / "missing")
        with patch.object(actions.shutil, "which", return_value=str(micro)) as which:
            self.assertEqual(self.invoke(["todo", "edit"])[0], 0)
            which.assert_called_once_with("micro", path="")
        self.runtime.events.clear()
        with patch.object(actions.shutil, "which", return_value=None):
            code, reply = self.invoke(["todo", "edit"])
        self.assertEqual(code, 1)
        self.assertIn("Micro", reply["message"])
        self.assertEqual(self.runtime.events, [])

    def test_editor_rejects_outside_paths_escaping_symlinks_and_non_regular_targets(self):
        self.micro()
        outside = self.root / "outside.md"
        outside.write_text("private")
        escape = self.helper.todo / "escape.md"
        escape.symlink_to(outside)
        directory = self.helper.todo / "directory.md"
        directory.mkdir()
        for path in [outside, escape, directory, self.helper.todo / "../outside.md", self.helper.todo / "script.py"]:
            self.state(str(path) + "\n")
            code, reply = self.invoke(["todo", "edit"])
            self.assertEqual(code, 1, reply)
            self.assertEqual(reply["code"], "invalid-data")
        self.assertEqual(self.runtime.events, [])

    def test_symlinked_todo_root_and_calendar_output_are_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        self.helper.todo.rmdir()
        self.helper.todo.symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.invoke(["todo", "next"])[0], 1)
        self.helper.todo.unlink()
        self.helper.todo.mkdir()
        (self.helper.todo / "2-gcal.md").symlink_to(outside / "calendar.md")
        self.assertEqual(self.invoke(["calendar", "next"])[0], 1)
        self.assertEqual(self.runtime.events, [])

    def test_context_exact_numeric_bounded_and_unsupported_never_looks_up_focus(self):
        self.micro()
        for raw in ["", "{}", '{"workspaceId":true}', '{"workspaceId":0}', '{"workspaceId":2147483648}',
                    '{"workspaceId":4,"extra":1}', '{"workspaceId":4,"workspaceId":5}',
                    '{"workspaceId":"name:work"}', '{"workspaceId":"special:scratch"}', "x" * 129]:
            environment = {**self.environment, actions.CONTEXT_ENV: raw}
            for operation in [["todo", "edit"], ["calendar", "open"]]:
                code, reply = self.invoke(operation, environment=environment)
                self.assertEqual(code, 1, reply)
        self.assertEqual(self.runtime.events, [])

    def test_editor_rejects_wrong_workspace_class_pid_old_or_ambiguous_window(self):
        self.micro()
        for overrides in [{"workspace": {"id": 9}}, {"workspace": None}, {"workspace": {"id": True}},
                          {"pid": 99}, {"class": "other"}, {"address": '0x1";bad'}]:
            self.runtime = FakeRuntime()
            self.editor_window(**overrides)
            code, reply = self.invoke(["todo", "edit"])
            self.assertEqual(code, 1, reply)
            self.assertTrue(reply["launchAccepted"])
            self.assertFalse(reply["placementVerified"])
            self.assertLessEqual(self.runtime.elapsed, 5)
            self.assertFalse(any(event[0] == "dispatch" for event in self.runtime.events))
        self.runtime = FakeRuntime()
        self.editor_window()
        self.runtime.client_handler = lambda: [dict(self.runtime.window)]
        self.assertEqual(self.invoke(["todo", "edit"])[0], 1)
        self.assertFalse(any(event[0] == "dispatch" for event in self.runtime.events))
        self.runtime = FakeRuntime()
        self.editor_window()
        self.runtime.client_handler = lambda: ([dict(self.runtime.window), {**self.runtime.window, "address": "0x456"}]
                                               if self.runtime.launch_id else [])
        self.assertEqual(self.invoke(["todo", "edit"])[0], 1)
        self.assertFalse(any(event[0] == "dispatch" for event in self.runtime.events))

    def test_editor_detects_replaced_window_and_unconfirmed_geometry(self):
        self.micro()
        self.editor_window()
        def clients():
            if not self.runtime.launch_id:
                return []
            window = dict(self.runtime.window)
            if self.runtime.elapsed >= .15:
                window["pid"] = 99
            return [window]
        self.runtime.client_handler = clients
        code, reply = self.invoke(["todo", "edit"])
        self.assertEqual(code, 1, reply)
        self.assertFalse(any(event[0] == "dispatch" for event in self.runtime.events))
        self.runtime = FakeRuntime()
        self.editor_window()
        with patch.object(self.runtime, "dispatch", side_effect=lambda value: self.runtime.events.append(("dispatch", value))):
            code, reply = self.invoke(["todo", "edit"])
        self.assertEqual(code, 1)
        self.assertIn("geometry", reply["message"])
        self.assertFalse(reply["placementVerified"])

    def test_launch_uncertainty_never_retries(self):
        self.micro()
        self.runtime.launch_code = subprocess.TimeoutExpired(["hyprctl"], 2)
        code, reply = self.invoke(["todo", "edit"])
        self.assertEqual(code, 1)
        self.assertIsNone(reply["launchAccepted"])
        self.assertEqual(reply["code"], "timeout")
        self.assertEqual(sum(event[0] == "launch" for event in self.runtime.events), 1)

    def test_calendar_launch_focus_refresh_order_and_failure_visibility(self):
        def refresh(helper, generated):
            self.assertFalse(generated)
            self.runtime.events.append(("refresh",))
            raise actions.ActionError("local refresh failed")
        with patch.object(actions.UserActions, "refresh", refresh):
            code, reply = self.invoke(["calendar", "open"])
        self.assertEqual(code, 1)
        self.assertEqual([event[0] for event in self.runtime.events], ["launch", "dispatch", "refresh"])
        self.assertEqual(self.runtime.events[0][1:3], (["zen-browser", "calendar.google.com"], 4))
        self.assertEqual(self.runtime.events[1][1], 'hl.dsp.focus({ workspace = 1 })')
        self.assertTrue(reply["launchAccepted"])
        self.assertFalse(reply["placementVerified"])
        self.assertIn("local refresh failed", reply["message"])

    def test_calendar_open_generation_lock_returns_busy_after_one_launch_and_focus(self):
        original_refresh = actions.UserActions.refresh
        def refresh(helper, generated):
            self.assertFalse(generated)
            self.runtime.events.append(("refresh",))
            original_refresh(helper, generated)
        self.helper.locks.mkdir(parents=True)
        with (self.helper.locks / "generated-refresh.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(actions.UserActions, "refresh", refresh):
                code, reply = self.invoke(["calendar", "open"])
        self.assertEqual([event[0] for event in self.runtime.events], ["launch", "dispatch", "refresh"])
        self.assertEqual(self.runtime.events[0][1:3], (["zen-browser", "calendar.google.com"], 4))
        self.assertEqual(self.runtime.events[1][1], 'hl.dsp.focus({ workspace = 1 })')
        self.assertEqual(self.runtime.sleeps, [])
        self.assertEqual(list(self.helper.todo.iterdir()), [])
        self.assertFalse(self.helper.state.exists())
        self.assertEqual(code, 75)
        self.assertEqual(reply, {"ok": False, "code": "busy", "message": "Action selection or generation is busy",
                                 "launchAccepted": True, "placementVerified": False})

    def test_calendar_focus_failure_still_refreshes(self):
        self.runtime.dispatch_error = actions.ActionError("focus failed")
        with patch.object(actions.UserActions, "refresh") as refresh:
            code, reply = self.invoke(["calendar", "open"])
        refresh.assert_called_once_with(generated=False)
        self.assertEqual(code, 1)
        self.assertIn("focus failed", reply["message"])

    def test_calendar_failed_or_uncertain_launch_still_focuses_and_refreshes_once(self):
        for failure in [1, subprocess.TimeoutExpired(["hyprctl"], 2)]:
            self.runtime = FakeRuntime()
            self.runtime.launch_code = failure
            with patch.object(actions.UserActions, "refresh") as refresh:
                code, reply = self.invoke(["calendar", "open"])
            refresh.assert_called_once_with(generated=False)
            self.assertEqual(code, 1)
            self.assertEqual([event[0] for event in self.runtime.events], ["launch", "dispatch"])
            self.assertFalse(reply["placementVerified"])
            if isinstance(failure, Exception):
                self.assertIsNone(reply["launchAccepted"])
            else:
                self.assertFalse(reply["launchAccepted"])

    def test_refresh_typed_argv_weekend_generation_and_expense_publication(self):
        self.environment["EXPENSES_API_BASE_URL"] = 'https://example.invalid/$(literal); space'
        def run(argv, timeout):
            if argv[0] == "gcalcli":
                self.assertEqual(timeout, 25)
                return subprocess.CompletedProcess(argv, 0, "Sat Oct 24\n  11:00 - 12:00 Meeting\n", "")
            self.assertEqual(argv[0], "curl")
            self.assertEqual(argv[-2], "--")
            return subprocess.CompletedProcess(argv, 0, "expense output\n", "")
        self.runtime.run_handler = run
        code, reply = self.invoke(["calendar", "next"])
        self.assertEqual(code, 0, reply)
        commands = [event[1] for event in self.runtime.events if event[0] == "run"]
        self.assertEqual(commands[0], ["gcalcli", "agenda", "--military", "--details=end", "--details=location", "--width=300", "today", "tomorrow"])
        self.assertEqual(commands[1][-1], "2026-11-01")
        self.assertEqual(commands[2][-1], self.environment["EXPENSES_API_BASE_URL"] + "/api/exports/regenerate")
        self.assertEqual((self.helper.todo / "80-today.md").read_text(), "expense output\n")
        self.assertEqual((self.helper.todo / "81-week.md").read_text(), "expense output\n")
        self.assertEqual((self.helper.todo / "2-gcal.md").read_text(), "Sat Oct 24\n➡️  11:00-12:00   Meeting\n")

    def test_failed_download_retains_files_and_other_refreshes_are_attempted(self):
        self.write("80-today.md", "last successful expense\n")
        self.write("2-gcal.md", "last successful calendar\n")
        self.environment["EXPENSES_API_BASE_URL"] = "https://example.invalid"
        def run(argv, timeout):
            if argv[0] == "gcalcli":
                raise actions.ActionError("network timed out", "timeout")
            return subprocess.CompletedProcess(argv, 22, "bad partial content", "failure")
        self.runtime.run_handler = run
        code, reply = self.invoke(["calendar", "next"])
        self.assertEqual(code, 1)
        self.assertIn("network timed out", reply["message"])
        self.assertIn("Expense refresh failed", reply["message"])
        self.assertEqual((self.helper.todo / "80-today.md").read_text(), "last successful expense\n")
        self.assertEqual((self.helper.todo / "2-gcal.md").read_text(), "last successful calendar\n")
        self.assertEqual(len(self.runtime.events), 5)

    def test_cached_offline_render_and_auth_notification_is_explicit_handoff_once(self):
        self.helper.cache.mkdir(parents=True)
        (self.helper.cache / "day.cache").write_text("Sat Oct 24\n  09:00 - 10:00 Cached\n")
        self.runtime.run_handler = lambda argv, timeout: subprocess.CompletedProcess(argv, 1, "", "invalid_grant Token has been expired or revoked")
        code, reply = self.invoke(["calendar", "open"])
        self.assertEqual(code, 1)
        launches = [event for event in self.runtime.events if event[0] == "launch"]
        self.assertEqual(len(launches), 2)
        self.assertEqual(launches[1][1][0], "notify-send")
        self.assertFalse(any("gcalcli-auth-notify.sh" in event[1] for event in launches))
        self.assertIn("expired", reply["message"])
        self.assertEqual((self.helper.todo / "2-gcal.md").read_text(), "󱦃 \nSat Oct 24\n▕  09:00-10:00   Cached\n")
        self.assertEqual((self.helper.todo / "99-gcal_week.md").read_text(), "󱦃 No Data\n")

    def test_generation_nonblocking_lock_prevents_network_and_preserves_selection(self):
        self.helper.locks.mkdir(parents=True)
        with (self.helper.locks / "generated-refresh.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, reply = self.invoke(["calendar", "next"])
        self.assertEqual(code, 75)
        self.assertEqual(reply["code"], "busy")
        self.assertTrue((self.helper.state / "gcal-current").exists())
        self.assertEqual(self.runtime.events, [])

    def test_generation_render_keeps_university_location_and_normalises_date(self):
        raw = 'Sat Oct 24\n\x1b[0;35m 10:00 - 11:00 COMP123 - Lecture<br/>\nLocation: Building (Room 1)\n\x1b[0;36m 14:00 - 15:00 Other\nLocation: Town <Centre>\n'
        self.assertEqual(actions.render_calendar(raw, self.runtime.now()),
                         'Sat Oct 24\n▒  10:00-11:00   Lecture  Room 1\n▕  14:00-15:00   Other  Town Centre\n')

    def test_generation_render_zero_padded_single_digit_dates_keep_current_event_arrow(self):
        for day in range(1, 10):
            with self.subTest(day=day):
                now = datetime(2026, 10, day, 11, 30)
                date = now.strftime("%a %b %d")
                raw = date + "\n  11:00 - 12:00 Synthetic\n"
                self.assertEqual(actions.render_calendar(raw, now),
                                 date + "\n➡️  11:00-12:00   Synthetic\n")

    def test_weekday_and_sunday_week_boundaries(self):
        self.runtime.run_handler = lambda argv, timeout: subprocess.CompletedProcess(argv, 0, "No events\n", "")
        for now, expected in [(datetime(2026, 10, 23), "sunday"), (datetime(2026, 10, 25), "2026-11-01")]:
            with patch.object(self.runtime, "now", return_value=now):
                self.assertEqual(self.invoke(["calendar", "open"])[0], 0)
            self.assertEqual(self.runtime.events[-1][1][-1], expected)

    def test_selection_special_files_and_invalid_utf8_fail_before_launch(self):
        self.micro()
        path = self.state("placeholder")
        path.write_bytes(b"\xff")
        self.assertEqual(self.invoke(["todo", "edit"])[0], 1)
        path.unlink()
        os.mkfifo(path)
        self.assertEqual(self.invoke(["todo", "edit"])[0], 1)
        self.assertEqual(self.runtime.events, [])

    def test_lock_symlink_and_fifo_cannot_redirect_or_block_an_action(self):
        self.helper.locks.mkdir(parents=True)
        path = self.helper.locks / "widget-todo.lock"
        outside = self.root / "outside-lock"
        outside.write_text("unchanged")
        path.symlink_to(outside)
        self.assertEqual(self.invoke(["todo", "next"])[0], 1)
        self.assertEqual(outside.read_text(), "unchanged")
        path.unlink()
        os.mkfifo(path)
        self.assertEqual(self.invoke(["todo", "next"])[0], 1)
        self.assertEqual(self.runtime.events, [])

    def test_invalid_operation_never_executes_and_selection_bytes_are_not_commands(self):
        for argv in [[], ["todo", "next", "extra"], ["todo next"], ["sh", "-c"], ["calendar", "auth"]]:
            self.assertEqual(self.invoke(argv)[0], 1)
        self.micro()
        self.state("$(touch /bad)\n")
        self.assertEqual(self.invoke(["todo", "edit"])[0], 1)
        self.state("x" * 4097)
        self.assertEqual(self.invoke(["todo", "edit"])[0], 1)
        self.assertEqual(self.runtime.events, [])

    def test_runtime_launch_uses_existing_launcher_with_no_finite_context_leak(self):
        import sys
        from types import SimpleNamespace
        launch = unittest.mock.Mock(return_value=0)
        module = SimpleNamespace(active_cursor_environment=lambda: {"XCURSOR_SIZE": "24"}, launch_detached=launch)
        with patch.dict(sys.modules, {"desktop_exec": module}):
            runtime = actions.Runtime(self.environment)
            self.assertEqual(runtime.launch(["kitty", "literal ; arg"], 4, "widget-action-test"), 0)
        argv, cwd, environment = launch.call_args.args
        self.assertEqual(argv, ["kitty", "literal ; arg"])
        self.assertIsNone(cwd)
        self.assertNotIn(actions.CONTEXT_ENV, environment)
        self.assertEqual(environment["XCURSOR_SIZE"], "24")
        self.assertEqual(launch.call_args.kwargs, {"workspace_id": 4, "launch_id": "widget-action-test", "timeout_seconds": 2})

    def test_finite_runner_drains_both_pipes_after_direct_exit_without_detaching(self):
        child, selector = self.finite_child([("stdout", b"literal output"), ("stderr", b"diagnostic"),
                                             ("stdout", b""), ("stderr", b"")], exited=True)
        runtime = actions.Runtime(self.environment)
        runtime.clock = self.runtime.clock
        argv = ["gcalcli", "literal ; $(argument)"]
        with patch.object(actions.subprocess, "Popen", return_value=child) as spawn, \
                patch.object(actions.selectors, "DefaultSelector", return_value=selector), \
                patch.object(actions.os, "set_blocking"), \
                patch.object(actions.os, "read", side_effect=lambda fd, size: selector.data):
            result = runtime.run(argv, 25)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "literal output", "diagnostic"))
        self.assertEqual(spawn.call_args.args, (argv,))
        self.assertEqual(set(spawn.call_args.kwargs), {"env", "stdin", "stdout", "stderr"})
        self.assertEqual(spawn.call_args.kwargs["env"], self.environment)
        self.assertFalse(child.killed)
        self.assertFalse(selector.keys)

    def test_finite_runner_timeout_overflow_and_cancellation_kill_its_direct_child(self):
        for mode in ["timeout", "overflow", "cancel"]:
            child, selector = self.finite_child([("stdout", b"x" * (actions.MAX_FILE_BYTES + 1))]
                                                if mode == "overflow" else [], exited=False)
            runtime = actions.Runtime(self.environment)
            runtime.clock = self.runtime.clock
            if mode == "cancel":
                selector.select = unittest.mock.Mock(side_effect=KeyboardInterrupt)
            with patch.object(actions.subprocess, "Popen", return_value=child), \
                    patch.object(actions.selectors, "DefaultSelector", return_value=selector), \
                    patch.object(actions.os, "set_blocking"), \
                    patch.object(actions.os, "read", side_effect=lambda fd, size: selector.data):
                with self.assertRaises(KeyboardInterrupt if mode == "cancel" else actions.ActionError) as error:
                    runtime.run(["fake-command"], .12)
            self.assertTrue(child.killed, mode)
            self.assertGreaterEqual(child.waits, 1)
            if mode != "cancel":
                self.assertEqual(error.exception.code, mode)

    def finite_child(self, events, exited):
        """Model a child and pipe readiness without starting a process or thread."""
        from types import SimpleNamespace
        class Child:
            stdout = SimpleNamespace(fileno=lambda: 101)
            stderr = SimpleNamespace(fileno=lambda: 102)
            killed = False
            waits = 0
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def poll(self):
                return 0 if exited or self.killed else None
            def wait(self):
                self.waits += 1
                return 0
            def kill(self):
                self.killed = True
        fake_runtime = self.runtime
        class Selector:
            def __init__(self):
                self.keys = {}
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def register(self, stream, event, name):
                self.keys[stream.fileno()] = SimpleNamespace(fileobj=stream, fd=stream.fileno(), data=name)
            def unregister(self, stream):
                del self.keys[stream.fileno()]
            def get_map(self):
                return self.keys
            def select(self, timeout):
                fake_runtime.elapsed += min(timeout, .05)
                if not events:
                    return []
                name, self.data = events.pop(0)
                return [(next(key for key in self.keys.values() if key.data == name), 1)]
        return Child(), Selector()


if __name__ == "__main__":
    unittest.main()
