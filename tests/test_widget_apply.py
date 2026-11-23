"""Widget-only Apply uses real disposable settings, generations and recovery."""
import json
import copy
import unittest
from unittest.mock import patch

from themes.tests import test_apply_owners as owner_tests
from themes.lib.blox_theme import runtime
from themes.lib.blox_theme.apply_owners import create_widget_apply, open_existing_apply
from themes.lib.blox_theme.apply_coordinator import ApplyError
from themes.lib.blox_theme.composition import mark_managed
from themes.lib.blox_theme.core import load_theme, widget_model
from shell.scripts import settings_runtime


class WidgetApplyTests(unittest.TestCase):
    setUp = owner_tests.ApplyOwnersTests.setUp

    def initialise(self):
        runtime.state_dir().mkdir(parents=True, mode=0o700)
        runtime.state_dir().parent.chmod(0o700)
        self.assertTrue(self.settings.set('targets.widgets.enabled', True, self.settings.get().revision).ok)
        path, theme = load_theme('catppuccin-mocha')
        runtime.apply_theme(path, theme, ('btop', 'micro', 'widgets'), run_command=self.runner,
                            activate_only=True)
        profile = {'schemaVersion': 1, 'widgets': [widget_model().default_widget('clock', 'acceptance-clock')]}
        self.assertTrue(self.settings.set('widgets', profile, self.settings.get().revision).ok)
        return self.settings.get().revision

    def test_isolated_publication_and_receipt(self):
        revision = self.initialise()
        before_path, before = runtime.current_generation()
        before_bytes = {name: (before_path / name).read_bytes() for name in before['files'] if name != 'widgets/profile.json'}
        settings_bytes = (self.settings.root / 'blox/settings.json').read_bytes()
        coordinator, request = create_widget_apply(revision)
        def seed_composition(current):
            for component in ('theme-metadata', 'appearance'):
                current = mark_managed(current, component, theme_id=request['themeId'],
                                       source_digest=request['sourceDigest'], generation_id=before_path.name,
                                       revision=None, digest='a' * 64)
            return current
        coordinator.ledger.update(seed_composition, expected_revision=0)
        ledger_before = coordinator.ledger.read()
        result = coordinator.apply(request)
        self.assertEqual(result['code'], 'ok', result)
        self.assertEqual(set(result['targets']), {'widgets'})
        path, after = runtime.current_generation()
        for name, content in before_bytes.items():
            self.assertEqual((path / name).read_bytes(), content)
        for key in ('theme_id', 'source', 'source_sha256', 'origin', 'derived'):
            self.assertEqual(after.get(key), before.get(key))
        self.assertEqual(json.loads((path / 'widgets/profile.json').read_text()), self.settings.get().data['widgets'])
        self.assertEqual((self.settings.root / 'blox/settings.json').read_bytes(), settings_bytes)
        ledger_after = coordinator.ledger.read()
        for name, component in ledger_before['components'].items():
            if name != 'widgets': self.assertEqual(ledger_after['components'][name], component)
        for key in ('themeId', 'sourceDigest'):
            self.assertEqual(ledger_after['activeTheme'][key], ledger_before['activeTheme'][key])
        self.assertEqual(self.hyprland_commands, [])
        self.assertTrue(open_existing_apply().finish()['journalReleased'])

    def test_stale_revision_and_profile_refused(self):
        revision = self.initialise()
        before = runtime.current_generation()[0]
        with self.assertRaisesRegex(ApplyError, 'revision conflict'):
            create_widget_apply(revision - 1)
        coordinator, request = create_widget_apply(revision)
        request['profileDigest'] = '0' * 64
        with self.assertRaisesRegex(ApplyError, 'profile changed'):
            coordinator.apply(request)
        self.assertEqual(runtime.current_generation()[0], before)
        self.assertFalse((coordinator.journal_dir / 'apply.json').exists())

    def test_invalid_saved_profile_refused(self):
        revision = self.initialise()
        before = runtime.current_generation()[0]
        settings_path = self.settings.root / 'blox/settings.json'
        document = json.loads(settings_path.read_text())
        document['widgets'] = {'invalid': True}
        settings_path.write_text(json.dumps(document))
        response = settings_runtime.run_request('apply-widgets', json.dumps({'expectedRevision': revision}))
        self.assertFalse(response['ok'])
        self.assertEqual(runtime.current_generation()[0], before)

    def test_mutation_after_request_creation_refused(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        before = runtime.current_generation()[0]
        self.settings.set('bar.layout.position', 'right', revision)
        with self.assertRaisesRegex(ApplyError, 'revision conflict'):
            coordinator.apply(request)
        self.assertEqual(runtime.current_generation()[0], before)
        self.assertEqual(self.settings.get().data['bar']['layout']['position'], 'right')

    def test_competing_generation_during_publication_is_preserved(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        original = coordinator.owners['widgets'].apply
        path, theme = load_theme('catppuccin-mocha')
        competing = []
        def race(payload):
            runtime.apply_theme(path, theme, ('micro',), run_command=self.runner, activate_only=True)
            competing.append(runtime.current_generation()[0])
            return original(payload)
        coordinator.owners['widgets'].apply = race
        result = coordinator.apply(request)
        self.assertEqual(result['code'], 'observation-conflict', result)
        self.assertEqual(runtime.current_generation()[0], competing[0])
        with self.assertRaises(ApplyError): open_existing_apply().roll_back()
        self.assertEqual(runtime.current_generation()[0], competing[0])

    def test_active_transaction_refused(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        coordinator.apply(request)
        before = runtime.current_generation()[0]
        other, payload = create_widget_apply(revision)
        with self.assertRaisesRegex(ApplyError, 'previous Apply'):
            other.apply(payload)
        self.assertEqual(runtime.current_generation()[0], before)
        coordinator.finish()

    def test_failed_publication_restores_and_cold_recovery(self):
        revision = self.initialise()
        before = runtime.current_generation()[0]
        coordinator, request = create_widget_apply(revision)
        with patch.object(runtime, '_switch_generation', side_effect=OSError('publication failed')):
            result = coordinator.apply(request)
        self.assertEqual(result['phase'], 'partial', result)
        self.assertEqual(runtime.current_generation()[0], before)
        cold = open_existing_apply()
        cold.roll_back()
        self.assertFalse((coordinator.journal_dir / 'apply.json').exists())

    def test_interrupted_transaction_recovers_without_settings_restore(self):
        revision = self.initialise()
        before = runtime.current_generation()[0]
        coordinator, request = create_widget_apply(revision)
        # Simulate death after atomic generation publication, before owner receipt.
        original = coordinator.owners['widgets'].apply
        def interrupted(payload):
            original(payload)
            raise KeyboardInterrupt()
        coordinator.owners['widgets'].apply = interrupted
        with self.assertRaises(KeyboardInterrupt): coordinator.apply(request)
        self.assertNotEqual(runtime.current_generation()[0], before)
        self.assertTrue(open_existing_apply().recover())
        self.assertEqual(runtime.current_generation()[0], before)
        self.assertEqual(self.settings.get().revision, revision)

    def test_competitor_after_publication_cannot_be_certified(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        publish = runtime.apply_theme
        competitors = []
        def race(*args, **kwargs):
            result = publish(*args, **kwargs)
            theme = copy.deepcopy(coordinator.owners['widgets'].rendered_theme)
            theme['widgets']['widgets'][0]['id'] = 'foreign-clock'
            foreign, _ = publish(coordinator.owners['widgets'].theme_path, theme, ('widgets',),
                                 activate_only=True, preserve_history=True,
                                 widget_generation=runtime.current_generation()[0].name)
            competitors.append(foreign['generation_id'])
            return result
        with patch.object(runtime, 'apply_theme', side_effect=race):
            result = coordinator.apply(request)
        self.assertEqual(result['code'], 'observation-conflict', result)
        self.assertEqual(runtime.current_generation()[0].name, competitors[0])
        self.assertNotEqual(result['targets']['widgets']['state'], 'success')

    def test_same_profile_competitor_survives_cold_recovery(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        apply = coordinator.owners['widgets'].apply
        def interrupted(payload):
            apply(payload)
            raise KeyboardInterrupt()
        coordinator.owners['widgets'].apply = interrupted
        with self.assertRaises(KeyboardInterrupt): coordinator.apply(request)
        owned = runtime.current_generation()[0]
        competitor, _ = runtime.apply_theme(coordinator.owners['widgets'].theme_path,
            coordinator.owners['widgets'].rendered_theme, ('widgets',), activate_only=True,
            preserve_history=True, widget_generation=owned.name)
        foreign = runtime.state_dir() / 'generations' / competitor['generation_id']
        with self.assertRaisesRegex(ApplyError, 'competing generation'):
            open_existing_apply().recover()
        self.assertEqual(runtime.current_generation()[0], foreign)
        self.assertTrue(foreign.is_dir())
        self.assertTrue(owned.is_dir())

    def test_same_profile_replacement_conflicts_at_finish(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        self.assertEqual(coordinator.apply(request)['code'], 'ok')
        runtime.apply_theme(coordinator.owners['widgets'].theme_path,
            coordinator.owners['widgets'].rendered_theme, ('widgets',), activate_only=True,
            preserve_history=True, widget_generation=runtime.current_generation()[0].name)
        foreign = runtime.current_generation()[0]
        self.assertTrue(coordinator.finish()['observationConflict'])
        self.assertEqual(runtime.current_generation()[0], foreign)

    def test_public_api_reports_finish_conflict(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        finish = coordinator.finish
        def race():
            runtime.apply_theme(coordinator.owners['widgets'].theme_path,
                coordinator.owners['widgets'].rendered_theme, ('widgets',), activate_only=True,
                preserve_history=True, widget_generation=runtime.current_generation()[0].name)
            return finish()
        with patch('themes.lib.blox_theme.apply_owners.create_widget_apply', return_value=(coordinator, request)), \
                patch.object(coordinator, 'finish', side_effect=race):
            response = settings_runtime.run_request('apply-widgets', json.dumps({'expectedRevision': revision}))
        self.assertFalse(response['ok'], response)
        self.assertTrue(response['data']['widgetApply']['receipt']['observationConflict'])

    def test_changed_or_occupied_publication_identity_refused(self):
        revision = self.initialise()
        coordinator, request = create_widget_apply(revision)
        request['widgetPublication'] = 'invalid'
        before = runtime.current_generation()[0]
        with self.assertRaisesRegex(ApplyError, 'publication identity'):
            coordinator.apply(request)
        self.assertEqual(runtime.current_generation()[0], before)
        coordinator, request = create_widget_apply(revision)
        (runtime.state_dir() / 'generations' / request['widgetPublication']).mkdir()
        result = coordinator.apply(request)
        self.assertEqual(result['targets']['widgets']['state'], 'failure', result)
        self.assertTrue(result['targets']['widgets']['publicationConflict'])
        self.assertEqual(runtime.current_generation()[0], before)
        self.assertTrue((runtime.state_dir() / 'generations' / request['widgetPublication']).is_dir())

    def test_cli_uses_revisioned_settings_owner(self):
        from shell.scripts import bloxctl
        from types import SimpleNamespace
        response = {'version': 1, 'ok': True, 'code': 'ok', 'message': '', 'data': {}}
        with patch.object(bloxctl, 'call_owner', return_value=response) as owner:
            code, result = bloxctl.run_settings(SimpleNamespace(settings_command='apply-widgets', revision=42))
        self.assertEqual(code, 0)
        arguments = owner.call_args
        self.assertEqual(arguments.kwargs, {'target': 'settings'})
        self.assertEqual(arguments.args[1][0], 'apply-widgets')
        self.assertEqual(json.loads(arguments.args[1][1]), {'expectedRevision': 42})

    def test_public_settings_route_leaves_settings_state_unreconciled(self):
        revision = self.initialise()
        response = settings_runtime.run_request('apply-widgets', json.dumps({'expectedRevision': revision}))
        self.assertTrue(response['ok'], response)
        self.assertIsNone(response['data']['settings'])
        self.assertEqual(response['data']['changedComponents'], [])
        self.assertEqual(response['data']['commitState'], 'not-applicable')
        self.assertTrue(response['data']['widgetApply']['receipt']['journalReleased'])


if __name__ == '__main__': unittest.main()
