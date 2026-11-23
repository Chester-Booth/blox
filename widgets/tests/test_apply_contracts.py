"""Fresh profiles through Settings, generation inputs and portable import review."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest

from shell.scripts.settings_document import SettingsDocument
from themes.lib.blox_theme.apply_owners import rendering_theme
from themes.lib.blox_theme.component_bundle import export_components, import_components, review_import, review_export
from themes.lib.blox_theme.core import load_theme, widget_model
from themes.lib.blox_theme.trust import strip_widget_document
from themes.lib.blox_theme.portability import PortabilityFailure


class ApplyProfileContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config'
        self.config.mkdir(mode=0o700)
        self.store = SettingsDocument(self.config)
        self.model = widget_model()
        _, self.theme = load_theme('catppuccin-mocha')

    def profile(self, *widgets):
        return {'schemaVersion': 1, 'widgets': list(widgets)}

    def test_settings_schema_embeds_the_current_shared_profile_contract(self):
        shared = json.loads(self.model.SCHEMA_PATH.read_text())
        shared.pop('$schema', None)
        shared.pop('$id', None)
        expected = json.loads(json.dumps(shared).replace('#/$defs/', '#/$defs/widgetProfile/$defs/'))
        self.assertEqual(expected, self.store.schema['$defs']['widgetProfile'])

    def test_settings_preserves_full_profile_and_empty_clears_source(self):
        clock = self.model.default_widget('clock', 'clock')
        clock['appearance']['backgroundOpacity'] = 0.35
        clock['workspaces'] = {'mode': 'include', 'ids': ['special:notes'], 'ranges': [[2, 5]]}
        profile = self.profile(clock)
        result = self.store.set('widgets', profile, 0)
        self.assertTrue(result.ok, result.data)
        self.assertEqual(profile, self.store.get().data['widgets'])
        self.theme['widgets'] = profile
        saved = copy.deepcopy(result.data)
        saved['widgets'] = self.model.default_profile()
        rendered = rendering_theme(self.theme, saved)
        self.assertEqual(self.model.default_profile(), rendered['widgets'])
        self.assertEqual(profile, self.theme['widgets'])
        self.assertFalse((self.config / 'blox/widgets.json').exists())

    def test_settings_rejects_old_or_incomplete_profiles_without_repair(self):
        sparse = self.store._migrate({'schemaVersion': 1, 'revision': 0, 'targets': {'widgets': {}}})
        self.assertEqual(self.store.defaults['targets']['widgets'], sparse['targets']['widgets'])
        for profile in ({'items': []}, {'widgets': []}, {'schemaVersion': 1},
                        {'schemaVersion': 1, 'widgets': [], 'style': {}},
                        self.profile(self.model.default_widget('clock', 'same'), self.model.default_widget('clock', 'same'))):
            with self.subTest(profile=profile):
                result = self.store.set('widgets', profile, 0)
                self.assertFalse(result.ok)
                self.assertFalse((self.config / 'blox/settings.json').exists())
        directory = self.config / 'blox'
        directory.mkdir(mode=0o700, exist_ok=True)
        path = directory / 'settings.json'
        path.write_text(json.dumps({'schemaVersion': 1, 'revision': 0, 'widgets': {'widgets': []}}))
        path.chmod(0o600)
        self.assertFalse(self.store.get().ok)
        self.assertNotIn('schemaVersion', json.loads(path.read_text())['widgets'])

    def test_disabled_import_does_not_require_opening_retained_command_file(self):
        item = self.model.default_widget('terminal', 'terminal', {'command': [str(self.root / 'missing-command')]})
        item['enabled'] = False
        settings = copy.deepcopy(self.store.defaults)
        settings['widgets'] = self.profile(item)
        self.assertEqual([], review_export(self.theme, settings, 'full', wallpaper=False))
        path = self.root / 'disabled.blox-theme'
        export_components(self.theme, settings, path, 'custom',
                          selected={'theme-metadata', 'appearance', 'widgets'}, wallpaper=False)
        _, imported, _ = import_components(path, self.theme, self.store.defaults, self.root / 'blox-user', install_assets=False)
        self.assertEqual(settings['widgets'], imported['widgets'])

    def test_loose_import_preserves_explicit_profile_and_reviews_untrusted_paths(self):
        from shell.scripts import bundle_runtime
        from unittest import mock
        theme = copy.deepcopy(self.theme)
        theme['widgets'] = self.profile(self.model.default_widget('terminal', 'terminal',
            {'command': [str(self.root / 'missing-script'), 'literal argument']}))
        source = self.root / 'incoming.json'
        source.write_text(json.dumps(theme))
        with mock.patch.dict('os.environ', {'BLOX_USER_DATA_DIR': str(self.root / 'blox-user')}):
            result = bundle_runtime.run('inspect', {'theme': str(source), 'path': str(source)}, self.store)
        self.assertIn('widgets', result['components'])
        self.assertEqual(1, len(result['scripts']))
        self.assertIn('missing-script', result['scripts'][0]['contents'])
        self.assertFalse((self.config / 'blox/settings.json').exists())
        self.assertFalse((self.root / 'blox-user').exists())

    def test_loose_import_empty_clears_and_absent_profile_preserves_saved_widgets(self):
        from shell.scripts import bundle_runtime
        from unittest import mock
        saved = self.profile(self.model.default_widget('clock', 'clock'))
        self.assertTrue(self.store.set('widgets', saved, 0).ok)
        with mock.patch.dict('os.environ', {'BLOX_USER_DATA_DIR': str(self.root / 'blox-user')}):
            for supplied in (False, True):
                theme = copy.deepcopy(self.theme)
                theme['id'] = 'widget-clear' if supplied else 'widget-preserve'
                if supplied:
                    theme['widgets'] = self.model.default_profile()
                else:
                    theme.pop('widgets', None)
                source = self.root / (theme['id'] + '.json')
                source.write_text(json.dumps(theme))
                review = bundle_runtime.run('inspect', {'theme': str(source), 'path': str(source)}, self.store)
                bundle_runtime.run('import', {'theme': str(source), 'path': str(source),
                    'digest': review['digest'], 'revision': review['settingsRevision'],
                    'components': review['components'], 'sourceDigest': review['sourceDigest']}, self.store)
                self.assertEqual(self.model.default_profile() if supplied else saved, self.store.get().data['widgets'])
        self.assertEqual(2, self.store.get().revision)
        self.assertFalse((self.config / 'blox/widgets.json').exists())

    def test_settings_runtime_rejects_duplicate_profile_keys(self):
        from shell.scripts.settings_runtime import run_request
        response = run_request('set', json.dumps({'path': 'widgets', 'expectedRevision': 0,
            'valueJson': '{"schemaVersion":1,"schemaVersion":1,"widgets":[]}'}), self.store)
        self.assertFalse(response['ok'])
        self.assertEqual('invalid-data', response['code'])
        self.assertIn('duplicate JSON key', response['message'])
        self.assertFalse((self.config / 'blox/settings.json').exists())

    def test_terminal_policy_and_cap_round_trip_and_bind_executable_approval(self):
        item = self.model.default_widget('terminal', 'terminal', {'command': ['owned-terminal']})
        settings = copy.deepcopy(self.store.defaults)
        settings['widgets'] = self.profile(item)
        path = self.root / 'terminal.blox-theme'

        def export_review():
            path.unlink(missing_ok=True)
            export_components(self.theme, settings, path, 'custom',
                              selected={'theme-metadata', 'appearance', 'widgets'}, wallpaper=False)
            return review_import(path)[0]

        original = export_review()
        item['settings']['restartPolicy'] = 'always'
        changed = export_review()
        self.assertNotEqual(original['sha256'], changed['sha256'])
        with self.assertRaisesRegex(PortabilityFailure, 'approval digest differs'):
            import_components(path, self.theme, self.store.defaults, self.root / 'blox-user',
                              approvals={original['path']: original['sha256']}, install_assets=False)
        item['settings']['maxRuntimeSeconds'] = 42
        capped = export_review()
        self.assertNotEqual(changed['sha256'], capped['sha256'])
        result = self.store.set('widgets', settings['widgets'], 0)
        self.assertTrue(result.ok, result.data)
        self.assertEqual(settings['widgets'], SettingsDocument(self.config).get().data['widgets'])
        incomplete = copy.deepcopy(settings['widgets'])
        del incomplete['widgets'][0]['settings']['restartPolicy']
        self.assertFalse(self.store.set('widgets', incomplete, result.revision).ok)
        self.assertEqual(settings['widgets'], self.store.get().data['widgets'])

    def test_complete_command_actions_round_trip_and_change_whole_settings_consent(self):
        item = self.model.default_widget('command', 'actions', {'command': ['producer']})
        settings = copy.deepcopy(self.store.defaults); settings['widgets'] = self.profile(item)
        def review():
            path = self.root / 'actions.blox-theme'; path.unlink(missing_ok=True)
            export_components(self.theme, settings, path, 'custom', selected={'theme-metadata','appearance','widgets'}, wallpaper=False)
            return path, review_import(path)[0]
        _, original = review()
        item['settings']['actions']['left'] = dict(kind='run', command=['action', 'literal'],
            workingDirectory='', environment={'EXAMPLE':'value'}, timeoutSeconds=5)
        path, changed = review()
        self.assertNotEqual(original['sha256'], changed['sha256'])
        for field, value in [('command',['action','other']), ('environment',{'EXAMPLE':'other'}), ('timeoutSeconds',6), ('workingDirectory','/tmp')]:
            before = item['settings']['actions']['left'][field]; item['settings']['actions']['left'][field] = value
            _, altered = review(); self.assertNotEqual(changed['sha256'], altered['sha256'])
            item['settings']['actions']['left'][field] = before
        path, changed = review()
        with self.assertRaisesRegex(PortabilityFailure, 'approval digest differs'):
            import_components(path,self.theme,self.store.defaults,self.root/'blox-user',approvals={original['path']:original['sha256']},install_assets=False)
        _, safe, _ = import_components(path,self.theme,self.store.defaults,self.root/'blox-user',install_assets=False)
        self.assertFalse(safe['widgets']['widgets'][0]['enabled'])
        self.assertEqual(safe['widgets']['widgets'][0]['settings'],item['settings'])
        result=self.store.set('widgets',settings['widgets'],0); self.assertTrue(result.ok,result.data)
        self.assertEqual(SettingsDocument(self.config).get().data['widgets'],settings['widgets'])
        incomplete=copy.deepcopy(settings['widgets']); del incomplete['widgets'][0]['settings']['actions']
        self.assertFalse(self.store.set('widgets',incomplete,result.revision).ok)
        self.assertEqual(self.store.get().data['widgets'],settings['widgets'])

    def executable_profile(self):
        return self.profile(
            self.model.default_widget('terminal', 'terminal', {'command': ['/bin/echo', 'review me']}),
            self.model.default_widget('shortcuts', 'shortcuts', {'items': [{'id': 'run', 'label': 'Run', 'command': ['/bin/echo', 'click']}]}),
            self.model.default_widget('qml', 'community', {'manifest': 'community', 'providers': [], 'layouts': ['native'], 'settings': {}}),
            self.model.default_widget('clock', 'clock'))

    def test_untrusted_import_disables_execution_and_retains_valid_configuration(self):
        profile = self.executable_profile()
        safe, fields = strip_widget_document(profile)
        self.model.validate_profile(safe)
        self.assertEqual([False, False, False, True], [widget['enabled'] for widget in safe['widgets']])
        self.assertEqual(3, len(fields))
        for original, imported in zip(profile['widgets'], safe['widgets']):
            self.assertEqual(original['kind'], imported['kind'])
            self.assertEqual(original['settings'], imported['settings'])
        self.assertTrue(all(widget['enabled'] for widget in profile['widgets']))

    def test_component_import_reviews_every_executable_and_checks_digests(self):
        settings = copy.deepcopy(self.store.defaults)
        settings['widgets'] = self.executable_profile()
        path = self.root / 'widgets.blox-theme'
        export_components(self.theme, settings, path, 'custom',
                          selected={'theme-metadata', 'appearance', 'widgets'}, wallpaper=False)
        reviews = review_import(path)
        self.assertEqual(3, len(reviews))
        self.assertTrue(any(record['path'].endswith('.manifest') for record in reviews))
        imported_theme, safe, _ = import_components(path, self.theme, self.store.defaults, self.root / 'blox-user', install_assets=False)
        self.assertEqual(safe['widgets'], imported_theme['widgets'])
        self.assertEqual([False, False, False, True], [item['enabled'] for item in safe['widgets']['widgets']])
        approvals = {record['path']: record['sha256'] for record in reviews}
        approved_theme, approved, _ = import_components(path, self.theme, self.store.defaults, self.root / 'blox-user', approvals=approvals, install_assets=False)
        self.assertEqual(settings['widgets'], approved['widgets'])
        self.assertEqual(approved['widgets'], approved_theme['widgets'])
        approvals[reviews[0]['path']] = '0' * 64
        with self.assertRaisesRegex(PortabilityFailure, 'approval digest differs'):
            import_components(path, self.theme, self.store.defaults, self.root / 'blox-user', approvals=approvals, install_assets=False)
        self.assertFalse((self.root / 'blox-user').exists())


if __name__ == '__main__':
    unittest.main()
