"""The Settings restart action cannot stop a different shell instance."""
import subprocess
import unittest
from unittest.mock import Mock, patch

from shell.scripts.restart_settings_shell import restart
from shell.scripts.place_settings_window import place
import json


class SettingsShellRestartTests(unittest.TestCase):
    def test_service_pid_must_match_before_restart(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout='42\n'))
        with self.assertRaisesRegex(RuntimeError, 'not running in'):
            restart(43, runner)
        self.assertEqual(runner.call_count, 1)

    def test_bundle_is_centred_on_the_matching_settings_instance(self):
        windows = [dict(title='Export theme', pid=42, address='0x1'),
                   dict(title='Blox settings', pid=41, address='0x2', at=[0, 0], size=[100, 100]),
                   dict(title='Blox settings', pid=42, address='0x3', at=[200, 100], size=[1320, 860])]
        monitors = [dict(id=0, width=1920, height=1080, x=0, y=0, scale=1, reserved=[34, 0, 0, 0], focused=True)]
        def fake_run(cmd, **_kwargs):
            if cmd == ['hyprctl', 'clients', '-j']:
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(windows))
            if cmd == ['hyprctl', 'monitors', '-j']:
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(monitors))
            return subprocess.CompletedProcess(cmd, 0, stdout='ok\n')
        runner = Mock(side_effect=fake_run)
        with patch('shell.scripts.place_settings_window.subprocess.run', runner):
            place('Export theme', 42, 500, 480, 'Blox settings')
        dispatches = [call.args[0][-1] for call in runner.call_args_list if call.args[0][:2] == ['hyprctl', 'dispatch']]
        self.assertTrue(any('hl.dsp.focus' in d and 'address:0x1' in d for d in dispatches))
        self.assertTrue(any('bring_to_top' in d for d in dispatches))
        move_cmd = next(d for d in dispatches if 'move(' in d)
        self.assertIn('x = 610', move_cmd)
        self.assertIn('y = 290', move_cmd)
        self.assertIn('address:0x1', move_cmd)

    def test_modal_position_is_clamped_to_monitor_work_area(self):
        windows = [dict(title='Import theme', pid=42, address='0x9', monitor=0),
                   dict(title='Blox settings', pid=42, address='0x3', at=[1600, 0], size=[320, 400])]
        monitors = [dict(id=0, width=1920, height=1080, x=0, y=0, scale=1, reserved=[34, 0, 0, 0], focused=True)]
        def fake_run(cmd, **_kwargs):
            if cmd == ['hyprctl', 'clients', '-j']:
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(windows))
            if cmd == ['hyprctl', 'monitors', '-j']:
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(monitors))
            return subprocess.CompletedProcess(cmd, 0, stdout='ok\n')
        runner = Mock(side_effect=fake_run)
        with patch('shell.scripts.place_settings_window.subprocess.run', runner):
            place('Import theme', 42, 500, 480, 'Blox settings')
        move_cmd = next(call.args[0][-1] for call in runner.call_args_list if 'move(' in call.args[0][-1])
        self.assertIn('x = 1412', move_cmd)
        self.assertIn('y = 8', move_cmd)

    def test_own_service_can_restart(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout='42\n'))
        restart(42, runner)
        self.assertEqual(runner.call_args.args[0], ['systemctl', '--user', 'restart', 'quickshell.service'])

if __name__ == '__main__':
    unittest.main()
