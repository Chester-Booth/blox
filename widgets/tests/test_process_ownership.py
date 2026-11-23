"""Focused behavioural tests for process-group widget ownership."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from blox_widgets import ownership


class ProcessOwnershipTests(unittest.TestCase):
    def test_command_close_kills_descendants_in_process_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "child.pid"
            script = (
                "import pathlib, subprocess, sys, time; "
                "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                f"pathlib.Path({str(pidfile)!r}).write_text(str(p.pid)); "
                "time.sleep(60)"
            )
            proc = ownership.launch([sys.executable, "-c", script], os.environ, tmp)
            try:
                deadline = time.monotonic() + 3.0
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pidfile.exists())
                child_pid = int(pidfile.read_text().strip())
                self.assertEqual(os.getpgid(child_pid), proc.pgid)
            finally:
                proc.close()

            self.assertTrue(proc.closed)
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                if not Path(f"/proc/{child_pid}").exists():
                    break
                try:
                    if Path(f"/proc/{child_pid}/stat").read_text().split(") ")[1][0] == "Z":
                        break
                except (FileNotFoundError, ProcessLookupError):
                    break
                time.sleep(0.01)
            alive = Path(f"/proc/{child_pid}").exists() and (
                Path(f"/proc/{child_pid}/stat").read_text().split(") ")[1][0] != "Z"
                if Path(f"/proc/{child_pid}/stat").exists() else False
            )
            self.assertFalse(alive, f"descendant {child_pid} survived close()")

    def test_missing_cwd_and_missing_executable_raise_launch_error(self):
        with self.assertRaises(ownership.InvocationLaunchError) as cwd_err:
            ownership.launch([sys.executable, "-c", "pass"], os.environ, "/nonexistent-blox-dir-xyz")
        self.assertEqual(cwd_err.exception.phase, "cwd")

        with self.assertRaises(ownership.InvocationLaunchError) as exec_err:
            ownership.launch(["/nonexistent-blox-bin-xyz"], os.environ, "")
        self.assertEqual(exec_err.exception.phase, "exec")

    def test_terminal_pty_starts_and_closes_cleanly(self):
        proc = ownership.launch(
            [sys.executable, "-c", "import sys; print('hi-pty', flush=True)"],
            os.environ,
            "",
            terminal={"columns": 40, "rows": 10},
        )
        try:
            self.assertGreaterEqual(proc.fd, 0)
            self.assertIsNotNone(proc.exit_fd)
            deadline = time.monotonic() + 2.0
            while proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(proc.poll(), 0)
        finally:
            proc.close()
        self.assertEqual(proc.fd, -1)
        self.assertIsNone(proc.exit_fd)


if __name__ == "__main__":
    unittest.main()
