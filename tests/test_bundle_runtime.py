"""Exercise the production bundle bridge under isolated XDG roots."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from shell.scripts import bundle_runtime as bridge
from shell.scripts.settings_document import SettingsDocument
from themes.lib.blox_theme.component_bundle import export_components
from themes.lib.blox_theme.core import load_theme


class BundleRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {key: str(self.root / name) for key, name in
            [('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state'), ('XDG_DATA_HOME', 'data'), ('BLOX_USER_DATA_DIR', 'blox-user')]})
        self.env.start()
        self.addCleanup(self.env.stop)
        (self.root / "config").mkdir(mode=0o700)
        self.owner = SettingsDocument()
        _, self.theme = load_theme('catppuccin-frappe')
        self.theme = copy.deepcopy(self.theme)
        self.theme.update(id='bundle-probe', name='Bundle probe')
        self.source = self.root / 'source.json'
        self.source.write_text(json.dumps(self.theme))

    def bundle(self, selected=None):
        output = self.root / ('incoming-' + str(len(list(self.root.glob('incoming-*')))) + '.blox-theme')
        settings = self.owner.get().data
        settings['bar']['style']['edgeInset'] = 7
        export_components(self.theme, settings, output, 'custom', selected or {'theme-metadata', 'appearance', 'bar'}, wallpaper=False)
        return output

    def request(self, path):
        review = bridge.run('inspect', {'theme': str(self.source), 'path': str(path)})
        return {'theme': str(self.source), 'path': str(path), 'digest': review['digest'],
                'revision': review['settingsRevision'], 'sourceDigest': review['sourceDigest'],
                'components': review['components'], 'approvals': {}}

    def test_loose_theme_import_uses_review_without_changing_saved_sections(self):
        request = self.request(self.source)
        result = bridge.run('import', request)
        self.assertEqual(json.loads(Path(result['path']).read_text())['id'], 'bundle-probe')
        self.assertEqual(self.owner.get().revision, 0)
        self.assertFalse((self.root / 'state/blox/theme/current').exists())

    def test_dormant_companion_symlink_rejected_before_publishing_theme(self):
        request = self.request(self.bundle())
        directory = self.root / 'blox-user/themes'
        directory.mkdir(parents=True)
        victim = self.root / 'victim'
        victim.write_text('unchanged')
        (directory / 'bundle-probe.components.json').symlink_to(victim)
        with self.assertRaisesRegex(ValueError, 'Unsafe dormant'):
            bridge.run('import', request)
        self.assertEqual(victim.read_text(), 'unchanged')
        self.assertFalse((directory / 'bundle-probe.json').exists())

    def test_import_commits_selected_settings_once_without_activating_targets(self):
        request = self.request(self.bundle())
        result = bridge.run('import', request)
        self.assertEqual(result['revision'], 1)
        self.assertEqual(self.owner.get().data['bar']['style']['edgeInset'], 7)
        self.assertTrue(Path(result['path']).is_file())
        self.assertFalse((self.root / 'state/blox/theme/current').exists())
        self.assertEqual(self.owner.get().data['targets'], self.owner.defaults['targets'])

    def test_conflict_copy_keeps_original_and_allocates_unique_ids(self):
        bundle = self.bundle()
        result = bridge.run('import', self.request(bundle))
        original = Path(result['path']).read_bytes()
        request = self.request(bundle)
        request['copy'] = True
        first = bridge.run('import', request)
        self.assertEqual(first['id'], 'bundle-probe-copy')
        self.assertEqual(first['name'], 'Bundle probe copy')
        second = bridge.run('import', self.request(bundle) | {'copy': True})
        self.assertEqual(second['id'], 'bundle-probe-copy-2')
        self.assertEqual(Path(result['path']).read_bytes(), original)
        self.assertFalse((self.root / 'state/blox/theme/current').exists())

    def test_import_can_exclude_core_appearance(self):
        theme = copy.deepcopy(self.theme)
        theme['colours']['accent'] = '#123456'
        output = self.root / 'appearance.blox-theme'
        export_components(theme, self.owner.get().data, output, 'minimal', wallpaper=False)
        request = self.request(output)
        request['components'] = ['theme-metadata']
        result = bridge.run('import', request)
        imported = json.loads(Path(result['path']).read_text())
        self.assertEqual(imported['colours'], self.theme['colours'])
        self.assertEqual(imported['id'], theme['id'])
        self.assertEqual(self.owner.get().revision, 0)

    def test_real_review_export_inspect_import_roundtrip(self):
        request = {'theme': str(self.source), 'components': ['appearance', 'bar'], 'preset': 'custom'}
        review = bridge.run('review-export', request)
        self.assertEqual(review['scripts'], [])
        request.update(path=str(self.root / 'roundtrip.blox-theme'), revision=review['settingsRevision'], themeDigest=review['themeDigest'])
        exported = bridge.run('export', request)
        self.assertTrue(zipfile.is_zipfile(exported['path']))
        incoming = self.request(Path(exported['path']))
        imported = bridge.run('import', incoming)
        self.assertEqual(json.loads(Path(imported['path']).read_text())['colours'], self.theme['colours'])
        self.assertFalse((self.root / 'state/blox/theme/current').exists())

    def test_changed_bundle_rejected_before_theme_or_settings_write(self):
        bundle = self.bundle()
        request = self.request(bundle)
        bundle.write_bytes(bundle.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'changed since review'):
            bridge.run('import', request)
        self.assertEqual(self.owner.get().revision, 0)
        self.assertFalse((self.root / 'blox-user/themes/bundle-probe.json').exists())

    def test_stale_settings_review_preserves_existing_source(self):
        request = self.request(self.bundle())
        self.owner.set('bar.style.edgeInset', 4, 0)
        with self.assertRaisesRegex(ValueError, 'changed since review'):
            bridge.run('import', request)
        self.assertEqual(self.owner.get().data['bar']['style']['edgeInset'], 4)
        self.assertFalse((self.root / 'blox-user/themes/bundle-probe.json').exists())

    def test_source_replacement_requires_reviewed_digest(self):
        request = self.request(self.bundle())
        result = bridge.run('import', request)
        before = Path(result['path']).read_bytes()
        request = self.request(self.bundle())
        request['replace'] = True
        Path(result['path']).write_bytes(before + b' ')
        with self.assertRaisesRegex(Exception, 'changed since it was loaded'):
            bridge.run('import', request)
        self.assertEqual(Path(result['path']).read_bytes(), before + b' ')

    def test_export_custom_targets_omits_others_and_has_no_activation(self):
        request = {'theme': str(self.source), 'components': ['appearance', 'targets', 'target-appearance'],
                   'targets': ['kitty'], 'preset': 'custom'}
        reviewed = bridge.run('review-export', request)
        request.update(path=str(self.root / 'out.blox-theme'), revision=reviewed['settingsRevision'], themeDigest=reviewed['themeDigest'])
        bridge.run('export', request)
        with zipfile.ZipFile(request['path']) as archive:
            self.assertEqual(set(json.loads(archive.read('components/targets.json'))), {'kitty'})
            self.assertNotIn('components/wallpaper.json', archive.namelist())
        self.assertFalse((self.root / 'state/blox/theme/current').exists())

    def test_export_source_change_rejects_before_save(self):
        request = {'theme': str(self.source), 'components': ['appearance'], 'preset': 'custom'}
        review = bridge.run('review-export', request)
        request.update(path=str(self.root / 'out.blox-theme'), revision=review['settingsRevision'], themeDigest=review['themeDigest'])
        self.source.write_text(self.source.read_text() + ' ')
        with self.assertRaisesRegex(ValueError, 'changed since review'):
            bridge.run('export', request)
        self.assertFalse(Path(request['path']).exists())

    def test_script_ui_includes_full_contents_path_size_digest(self):
        record = {'path': '/home/probe/a.sh', 'name': 'a.sh', 'size': 40, 'sha256': 'f' * 64, 'contents': '\n'.join('echo test' for _ in range(9))}
        shown = bridge.scripts_for_ui([record])[0]
        self.assertEqual(shown['preview'], record['contents'])
        self.assertEqual(shown['id'], record['path'])
        self.assertIn(record['sha256'], shown['reason'])
        self.assertEqual(shown['viewMode'], 'expand')

    def test_section_import_is_atomic_at_one_revision(self):
        before = self.owner.get()
        updates = {'bar': copy.deepcopy(before.data['bar']), 'osd': copy.deepcopy(before.data['osd'])}
        updates['bar']['style']['edgeInset'] = 5
        result = self.owner.update_sections(updates, before.revision)
        self.assertTrue(result.ok)
        self.assertEqual(result.revision, 1)
        self.assertEqual(result.changed, ('bar', 'osd'))
        stale = self.owner.update_sections(updates, 0)
        self.assertEqual(stale.code, 'conflict')

if __name__ == '__main__':
    unittest.main()
