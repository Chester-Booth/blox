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


RESTORE_SPEC = importlib.util.spec_from_file_location("restore_focus", MODULE.with_name("restore_focus.py"))
restore_focus = importlib.util.module_from_spec(RESTORE_SPEC)
RESTORE_SPEC.loader.exec_module(restore_focus)


class PickerFocusRestoreTests(unittest.TestCase):
    def clients(self, address="0xabc", pid=42, window_class="editor"):
        import json
        return mock.Mock(returncode=0, stdout=json.dumps([{"address": address, "pid": pid, "class": window_class}]))

    def test_restores_only_the_matching_captured_window(self):
        with mock.patch.object(restore_focus.subprocess, "run", side_effect=[self.clients(), mock.Mock(returncode=0)]) as run:
            self.assertTrue(restore_focus.restore("abc", 42, "editor"))
        self.assertEqual(run.call_args.args[0], ["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({window='address:0xabc'}))"])

    def test_closed_or_reused_address_never_dispatches_focus(self):
        for clients in (self.clients(address="0xdef"), self.clients(pid=99), self.clients(window_class="other")):
            with self.subTest(clients=clients.stdout), mock.patch.object(restore_focus.subprocess, "run", return_value=clients) as run:
                self.assertFalse(restore_focus.restore("abc", 42, "editor"))
                self.assertEqual(run.call_count, 1)

    def test_invalid_address_and_unreadable_clients_never_dispatch(self):
        with mock.patch.object(restore_focus.subprocess, "run") as run:
            self.assertFalse(restore_focus.restore("abc';bad", 42, "editor"))
            self.assertFalse(restore_focus.restore("abc", 0, "editor"))
            run.assert_not_called()
        with mock.patch.object(restore_focus.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="invalid")) as run:
            self.assertFalse(restore_focus.restore("abc", 42, "editor"))
            self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
