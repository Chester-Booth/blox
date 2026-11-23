"""Tests use only owned Python subprocesses, never host applications."""
import json
import errno
import os
from pathlib import Path
import signal
import select
import subprocess
import sys
import time
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from blox_widgets.terminal import AnsiScreen, TerminalSession, TerminalLaunchError


class ScreenTests(unittest.TestCase):
    def test_incremental_unicode_and_wide_cells(self):
        screen = AnsiScreen(2, 8)
        encoded = "é界e\u0301".encode()
        for byte in encoded:
            screen.feed(bytes([byte]))
        self.assertEqual(screen.cells[0][:4], ["é", "界", "", "e\u0301"])
        self.assertNotIn("�", "".join(screen.cells[0]))

    def test_styles_blank_erasure_and_truecolour(self):
        screen = AnsiScreen(2, 8)
        screen.feed(b"\x1b[38;2;1;2;3;48;5;196;1;4;7m X\x1b[0m\r\x1b[2K")
        self.assertEqual(screen.cells[0], [" "] * 8)
        self.assertEqual(screen.styles[0], [(None, None, False, False, False)] * 8)
        screen.feed(b"\x1b[38;2;1;2;3mX")
        self.assertEqual(screen.runs(0)[0]["foreground"], "#010203")

    def test_erase_retains_cursor_and_current_background(self):
        screen = AnsiScreen(2, 8)
        screen.feed(b"abc\x1b[41m\x1b[2J")
        self.assertEqual((screen.row, screen.column), (0, 3))
        self.assertEqual(screen.styles[0][0][1], "#cc241d")
        screen.feed(b"x")
        self.assertEqual(screen.cells[0][3], "x")

    def test_wrap_scroll_and_alternate_screen(self):
        screen = AnsiScreen(2, 4)
        screen.feed(b"abcd")
        self.assertEqual(screen.row, 0)
        screen.feed(b"e")
        self.assertEqual(screen.cells[1][0], "e")
        screen.feed(b"\x1b[?1049hnew\x1b[?1049l")
        self.assertEqual("".join(screen.cells[0]), "abcd")
        self.assertEqual(screen.cells[1][0], "e")
        screen.feed(b"\r\nxyz")
        self.assertEqual(screen.cells[0][0], "e")

    def test_reverse_index_respects_scroll_region(self):
        screen = AnsiScreen(6, 8)
        screen.feed(b"top\r\nold-1\r\nold-2\r\nold-3\r\nfooter\x1b[2;4r\x1b[2;1H\x1bMnew")
        self.assertEqual(['top', 'new', 'old-1', 'old-2', 'footer', ''],
                         [''.join(row).rstrip() for row in screen.cells])

    def test_saved_cursor_and_character_erase_replace_cells(self):
        screen = AnsiScreen(2, 8)
        screen.feed(b"12:08\x1b7\x1b[1;4H\x1b[2X04\x1b8!")
        self.assertEqual('12:04!', ''.join(screen.cells[0]).rstrip())

    def test_maximum_styled_snapshot_fits_broker_bound(self):
        screen = AnsiScreen(50, 240)
        for row in range(50):
            screen.cells[row] = ["😀" + "\U0001d185" * 7] * 240
            screen.styles[row] = [("#000000" if col % 2 else "#ffffff", "#abcdef", True, True, True) for col in range(240)]
        rows = [dict(runs=screen.runs(row)) for row in range(50)]
        snapshot = dict(rows=rows, changedRuns=[dict(row=row, **run) for row, data in enumerate(rows) for run in data["runs"]])
        self.assertLess(len(json.dumps(snapshot).encode()), 8 * 1024 * 1024 - 4096)

    def test_control_strings_do_not_become_content(self):
        screen = AnsiScreen(1, 10)
        screen.feed(b"\x1b]0;ignored\x1b\\ok\x1bPignored\x1b\\!")
        self.assertEqual("".join(screen.cells[0]).rstrip(), "ok!")


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)

    def create(self, source, **settings):
        options = dict(command=[sys.executable, "-u", "-c", source], workingDirectory="", environment={}, columns=80, rows=24, maxRuntimeSeconds=0, restartPolicy="never")
        options.update(settings)
        session = TerminalSession(options, 7)
        self.addCleanup(session.close)
        return session

    def until(self, session, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            frame = session.poll()
            if frame is not None:
                last = frame
                if predicate(frame):
                    return frame
            time.sleep(.005)
        self.fail(f"owned command timed out, last snapshot {last}")

    def test_partial_then_settled_and_explicit_blank_patch(self):
        session = self.create("import time; print('abc',end='',flush=True); time.sleep(.15); print('\\r\\x1b[2K',end='',flush=True)", columns=10, rows=2)
        partial = self.until(session, lambda value: value["bytesObserved"] > 0)
        self.assertEqual(partial["readiness"], "partial")
        self.assertEqual(partial["generation"], 7)
        self.assertFalse(partial["sourceCapabilities"]["completeLiveFrames"])
        frames = []
        settled = self.until(session, lambda value: frames.append(value) or value["readiness"] == "settled")
        blank_runs = [run for frame in frames for run in frame["changedRuns"] if run["row"] == 0]
        self.assertTrue(blank_runs)
        self.assertTrue(all(cell == " " for cell in settled["rows"][0]["runs"][0]["cells"]))
        self.assertEqual(settled["exitCode"], 0)

    def test_resize_changes_pty_size_and_snapshot(self):
        session = self.create("import os,time; print(os.get_terminal_size().columns,flush=True); time.sleep(.5)", columns=10, rows=2)
        self.until(session, lambda value: value["bytesObserved"] > 0)
        session.resize(35, 7)
        frame = self.until(session, lambda value: value["columns"] == 35)
        self.assertEqual(frame["rowCount"], 7)
        self.assertEqual(os.get_terminal_size(session.fd).columns, 35)
        self.assertTrue(frame["changedRuns"])

    def test_input_and_environment_working_directory(self):
        session = self.create("import os; print(os.getcwd(),os.environ['BLOX_TEST'],flush=True); print(input(),flush=True)", workingDirectory="/tmp", environment={"BLOX_TEST": "owned"}, columns=40, rows=4)
        self.until(session, lambda value: value["bytesObserved"] > 0)
        self.assertEqual(session.write("hello\n"), 6)
        settled = self.until(session, lambda value: value["readiness"] == "settled")
        text = "\n".join("".join(run["text"] for run in row["runs"]) for row in settled["rows"])
        self.assertIn("/tmp owned", text)
        self.assertIn("hello", text)

    def test_close_kills_owned_group_and_reaps_direct_child(self):
        session = self.create("import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)']); print(p.pid,flush=True); time.sleep(10)")
        frame = self.until(session, lambda value: value["bytesObserved"] > 0)
        grandchild = int("".join(run["text"] for run in frame["rows"][0]["runs"]).strip())
        session.close()
        self.assertIsNotNone(session.process.returncode)
        self.assertEqual(session.fd, -1)
        self.assertIsNone(session.poll())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                state = Path(f"/proc/{grandchild}/stat").read_text().split()[2]
            except (FileNotFoundError, ProcessLookupError):
                break
            if state == "Z":
                break
            time.sleep(.005)
        else:
            os.kill(grandchild, signal.SIGKILL)
            self.fail("owned grandchild survived invocation cleanup")

    def test_launch_failure_and_exit_watch_failure_have_distinct_recovery_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(TerminalLaunchError):
                self.create('pass', workingDirectory=str(Path(temporary) / 'missing'))
        from blox_widgets import ownership
        before = len(self.supervision.events())
        with patch.object(ownership, 'launch', side_effect=ownership.OwnershipUnavailable('owned watch failure')):
            with self.assertRaises(ownership.OwnershipUnavailable):
                self.create('import time; time.sleep(10)')
        self.assertEqual(len(self.supervision.events()), before)
        processes = []
        launch = ownership.launch
        def admitted(*args, **kwargs):
            process = launch(*args, **kwargs)
            processes.append(process)
            return process
        with patch.object(ownership, 'launch', side_effect=admitted), \
             patch('blox_widgets.terminal.os.dup', side_effect=OSError(errno.EBADF, 'owned watch failure')):
            with self.assertRaises(OSError) as raised:
                self.create('import time; time.sleep(10)')
        self.assertNotIsInstance(raised.exception, TerminalLaunchError)
        self.assertEqual(len(processes), 1)
        self.assertIsNotNone(processes[0].returncode)
        self.supervision.assert_closed(self, processes[0])

    def test_broker_death_hangs_up_owned_foreground_group(self):
        command_source = "import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)']); print(p.pid,flush=True); time.sleep(10)"
        worker_source = f"""import json,sys,time
sys.path.insert(0, {str(Path(__file__).resolve().parents[1] / 'lib')!r})
from blox_widgets.terminal import TerminalSession
session=TerminalSession({{'command':[sys.executable,'-u','-c',{command_source!r}], 'workingDirectory':'', 'environment':{{}}, 'columns':80, 'rows':24, 'maxRuntimeSeconds':0, 'restartPolicy':'never'}}, 1)
deadline=time.monotonic()+3
while time.monotonic()<deadline:
    frame=session.poll()
    if frame and frame['bytesObserved']:
        grandchild=int(''.join(run['text'] for run in frame['rows'][0]['runs']).strip())
        print(json.dumps([session.process.pid,grandchild]),flush=True)
        time.sleep(10)
        break
    time.sleep(.005)
"""
        worker = subprocess.Popen([sys.executable, "-u", "-c", worker_source], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pids = []
        try:
            readable, _, _ = select.select([worker.stdout], [], [], 4)
            self.assertTrue(readable, "owned broker did not report its child")
            pids = json.loads(worker.stdout.readline())
            worker.kill()
            worker.wait(timeout=2)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                running = []
                for pid in pids:
                    try:
                        if Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z":
                            running.append(pid)
                    except FileNotFoundError:
                        pass
                if not running:
                    break
                time.sleep(.005)
            else:
                self.fail(f"owned group survived broker death: {running}")
        finally:
            if worker.poll() is None:
                worker.kill()
                worker.wait(timeout=2)
            worker.stdout.close()
            worker.stderr.close()

    def test_explicit_runtime_cap_and_generation_isolation(self):
        first = self.create("import time; print('old',flush=True); time.sleep(10)", maxRuntimeSeconds=.05)
        capped = self.until(first, lambda value: value["stopReason"] == "runtime-limit")
        self.assertTrue(first.closed)
        self.assertTrue(capped["exited"])
        second = self.create("print('new',flush=True)")
        settled = self.until(second, lambda value: value["readiness"] == "settled")
        self.assertNotIn("old", "".join(run["text"] for row in settled["rows"] for run in row["runs"]))

    def test_rejects_unbounded_or_legacy_settings_before_spawn(self):
        for options in [dict(command="echo no"), dict(command=["true"], columns=1000), dict(command=["true"], rows=100, columns=240), dict(command=["true"], cwd="/tmp"), dict(command=["true"], environment={"BAD=KEY": "x"})]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                complete = dict(command=[sys.executable], workingDirectory="", environment={}, columns=80, rows=24, maxRuntimeSeconds=0, restartPolicy="never")
                complete.update(options)
                TerminalSession(complete, 1)


if __name__ == "__main__":
    unittest.main()
