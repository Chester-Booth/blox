import importlib.util
import unittest
from pathlib import Path
from unittest import mock


MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/parent_guard.py"
SPEC = importlib.util.spec_from_file_location("parent_guard", MODULE)
parent_guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parent_guard)


class ParentGuardTests(unittest.TestCase):
    def test_rejects_an_already_orphaned_process(self):
        with self.assertRaisesRegex(RuntimeError, "already exited"):
            parent_guard.arm(1)

    def test_arms_linux_parent_death_signal_and_checks_for_a_race(self):
        libc = mock.Mock()
        libc.prctl.return_value = 0
        with mock.patch.object(parent_guard.ctypes, "CDLL", return_value=libc), \
             mock.patch.object(parent_guard.os, "getppid", return_value=42):
            parent_guard.arm(42)
        libc.prctl.assert_called_once_with(
            parent_guard.PR_SET_PDEATHSIG, parent_guard.signal.SIGTERM, 0, 0, 0
        )

    def test_detects_parent_exit_during_startup(self):
        libc = mock.Mock()
        libc.prctl.return_value = 0
        with mock.patch.object(parent_guard.ctypes, "CDLL", return_value=libc), \
             mock.patch.object(parent_guard.os, "getppid", return_value=43), \
             self.assertRaisesRegex(RuntimeError, "while starting"):
            parent_guard.arm(42)


if __name__ == "__main__":
    unittest.main()
