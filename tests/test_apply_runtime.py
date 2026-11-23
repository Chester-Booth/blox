"""Exercise error envelopes against a real isolated Apply coordinator."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

from shell.scripts import apply_runtime
from shell.scripts.settings_document import SettingsDocument
from themes.lib.blox_theme.apply_coordinator import ApplyCoordinator, ApplyError
from themes.lib.blox_theme.composition import CompositionDocument
from themes.tests.test_apply_coordinator import Core, Owner


class ApplyRuntimeErrorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'config').mkdir(mode=0o700)
        settings = SettingsDocument(self.root / 'config')
        settings.set('targets.kitty.enabled', True, settings.get().revision)
        self.core = Core('core')
        self.owner = Owner('kitty', 'appearance')
        self.coordinator = ApplyCoordinator(settings, CompositionDocument(self.root / 'state'),
                                            self.root / 'journal', self.core, {'kitty': self.owner})
        self.request = {'settingsRevision': settings.get().revision, 'themeId': 'fixture',
                        'sourceDigest': 'a' * 64, 'components': {'kitty': 'appearance'}, 'approvals': {}}

    def invoke(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = apply_runtime.main(args)
        return code, json.loads(output.getvalue().splitlines()[-1])

    def test_core_and_restore_failure_reports_the_actual_retained_journal(self):
        self.core.fail = True
        with patch.object(self.core, 'restore', side_effect=RuntimeError('restore blocked')), \
             patch.object(apply_runtime, 'create_apply', return_value=(self.coordinator, self.request)):
            code, response = self.invoke(['apply', '--theme', 'fixture'])
        self.assertEqual(code, 1)
        self.assertFalse(response['ok'])
        self.assertTrue((self.root / 'journal/apply.json').is_file())
        self.assertEqual(response['data']['phase'], 'restoring')
        self.assertFalse(response['data']['journalReleased'])
        self.assertTrue(response['data']['recoveryAvailable'])
        self.assertIn('restore incomplete', response['error'])
        self.assertIn('core failed', response['error'])
        self.assertIn('restore blocked', response['error'])
        self.assertEqual(response['data']['failureCause']['message'], 'core failed')
        retained = json.loads((self.root / 'journal/apply.json').read_text())
        self.assertEqual(retained['failureCause']['message'], 'core failed')
        with patch.object(apply_runtime, 'open_existing_apply', return_value=self.coordinator):
            code, cold_status = self.invoke(['status'])
        self.assertEqual(code, 0)
        self.assertIn('core failed', cold_status['data']['error'])
        self.assertIn('restore blocked', cold_status['data']['error'])
        if os.environ.get('BLOX_TEST_ERROR_EVIDENCE'):
            Path(os.environ['BLOX_TEST_ERROR_EVIDENCE']).write_text(json.dumps(response))
        self.core.fail = False
        with patch.object(apply_runtime, 'open_existing_apply', return_value=self.coordinator):
            code, restored = self.invoke(['recover'])
        self.assertEqual(code, 0)
        self.assertFalse((self.root / 'journal/apply.json').exists())
        self.assertEqual(self.core.value, {'old': 'core'})

    def test_failed_status_read_keeps_unknown_recovery_protected(self):
        owner = Mock()
        owner.status.side_effect = ValueError('bad journal')
        data = apply_runtime.error_status(owner)
        self.assertEqual(data['phase'], 'unknown')
        self.assertFalse(data['journalReleased'])
        self.assertTrue(data['recoveryAvailable'])

    def test_target_failure_survives_failed_restoration_and_cold_status(self):
        self.owner.fail = True
        with patch.object(self.owner, 'restore', side_effect=RuntimeError('target restore blocked')), \
             patch.object(apply_runtime, 'create_apply', return_value=(self.coordinator, self.request)):
            code, response = self.invoke(['apply', '--theme', 'fixture'])
        self.assertEqual(code, 1)
        self.assertIn('kitty failed', response['error'])
        self.assertIn('target restore blocked', response['error'])
        self.assertEqual(response['data']['failureCause']['target'], 'kitty')
        cold = ApplyCoordinator(self.coordinator.settings, self.coordinator.ledger,
                                self.root / 'journal', self.core, {'kitty': self.owner})
        status = cold.status()
        self.assertEqual(status['error'], response['data']['error'])
        self.assertEqual(status['failureCause']['message'], 'kitty failed')
        self.assertTrue(status['recoveryAvailable'])

    def test_superseded_partial_runtime_archives_failure_and_releases_only_receipt(self):
        self.owner.fail = True
        self.coordinator.apply(self.request)
        self.coordinator.settings.set('bar.layout.position', 'bottom', self.coordinator.settings.get().revision)
        settings_before = self.coordinator.settings.get().data
        with patch.object(apply_runtime, 'open_existing_apply', return_value=self.coordinator):
            code, status = self.invoke(['status'])
            self.assertEqual(code, 0)
            self.assertTrue(status['data']['actions']['abandonSuperseded'])
            code, response = self.invoke(['abandon'])
        self.assertEqual(code, 0)
        self.assertEqual(response['data']['code'], 'abandoned')
        self.assertTrue(response['data']['journalReleased'])
        self.assertEqual(self.coordinator.settings.get().data, settings_before)
        archive = json.loads(next((self.root / 'journal').glob('superseded-*.json')).read_text())
        self.assertEqual(archive['targets']['kitty']['state'], 'failure')
        self.assertFalse(archive['restorationAttempted'])
        self.assertFalse((self.root / 'journal/apply.json').exists())

    def test_proved_absence_is_distinct_from_an_unreadable_journal(self):
        with patch.object(apply_runtime, 'create_apply', side_effect=ApplyError('Invalid source')), \
             patch.object(apply_runtime, 'open_existing_apply', side_effect=ApplyError('no Apply transaction exists')):
            code, response = self.invoke(['apply', '--theme', 'fixture'])
        self.assertEqual(code, 1)
        self.assertTrue(response['data']['journalReleased'])
        self.assertFalse(response['data']['recoveryAvailable'])
        self.assertEqual(response['data']['phase'], 'none')

if __name__ == '__main__':
    unittest.main()
