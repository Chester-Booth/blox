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
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps(windows)))
        with patch('shell.scripts.place_settings_window.subprocess.run', runner):
            place('Export theme', 42, 500, 480, 'Blox settings')
        command = runner.call_args.args[0][-1]
        self.assertIn('x = 610', command)
        self.assertIn('y = 290', command)
        self.assertIn('address:0x1', command)

    def test_own_service_can_restart(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout='42\n'))
        restart(42, runner)
        self.assertEqual(runner.call_args.args[0], ['systemctl', '--user', 'restart', 'quickshell.service'])

if __name__ == '__main__':
    unittest.main()
