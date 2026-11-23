"""Strict workspace acceptance and literal quoting through a fake compositor."""
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('application_launcher', Path(__file__).resolve().parents[2]/'shell/scripts/launcher/desktop_exec.py')
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


class ApplicationLauncherTests(unittest.TestCase):
    def test_nonzero_and_uncertain_dispatch_never_fall_back_or_retry(self):
        for outcome in (1, subprocess.TimeoutExpired(['fake-hyprctl'],2), OSError('unavailable')):
            with self.subTest(outcome=outcome), patch.object(launcher.subprocess,'run') as run, patch.object(launcher.subprocess,'Popen') as popen:
                if isinstance(outcome,Exception):
                    run.side_effect=outcome
                    with self.assertRaises(type(outcome)):
                        launcher.launch_detached(['fake-app'],None,{},workspace_id=4,timeout_seconds=2)
                else:
                    run.return_value.returncode=outcome
                    self.assertEqual(launcher.launch_detached(['fake-app'],None,{},workspace_id=4),outcome)
                run.assert_called_once(); popen.assert_not_called()

    def test_explicit_unsupported_workspace_never_becomes_unplaced_launch(self):
        with patch.object(launcher.subprocess,'run') as run, patch.object(launcher.subprocess,'Popen') as popen:
            for workspace in (True,0,-1,'4','name:notes','special:notes',4.5):
                with self.subTest(workspace=workspace), self.assertRaises(ValueError):
                    launcher.launch_detached(['fake-app'],None,{},workspace_id=workspace)
            run.assert_not_called(); popen.assert_not_called()

    def test_command_keeps_every_argument_literal_and_clears_reserved_inheritance(self):
        argv=['fake-app', 'two words', "'quote'", '$(touch /bad)', '; bad', '\\', '\nvalue']
        environment={'PATH':'/fixture/bin:/usr/bin','XCURSOR_THEME':'literal $(theme)',
                     'BLOX_WIDGET_ACTION_CONTEXT':'forged'}
        command=launcher._workspace_command(argv,None,environment,4,'request-4')
        parts=shlex.split(command)
        self.assertEqual(parts[-len(argv):],argv)
        self.assertNotIn('BLOX_WIDGET_ACTION_CONTEXT=forged',parts)
        self.assertIn('XCURSOR_THEME=literal $(theme)',parts)
        self.assertIn('BLOX_LAUNCH_WORKSPACE=4',parts)
        with patch.object(launcher.subprocess,'run') as run, patch.object(launcher.subprocess,'Popen') as popen:
            run.return_value.returncode=0
            self.assertEqual(launcher.launch_detached(argv,None,environment,workspace_id=4,launch_id='request-4'),0)
            run.assert_called_once(); popen.assert_not_called()
            self.assertNotIn('BLOX_WIDGET_ACTION_CONTEXT',run.call_args.kwargs['env'])
        self.assertEqual(environment['BLOX_WIDGET_ACTION_CONTEXT'],'forged')


if __name__ == '__main__': unittest.main()
