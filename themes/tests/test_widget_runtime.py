from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / 'lib'))

from blox_theme.core import (
    apply_theme_defaults, default_widget_profile, defaults_schema_errors,
    list_themes, load_theme, render_theme, schema_errors, widget_model,
)


class ThemeWidgetProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.model = widget_model()
        _, self.theme = load_theme('catppuccin-mocha')

    def test_generation_preserves_the_shared_profile(self) -> None:
        item = self.model.default_widget('clock', 'desk-clock')
        item['workspaces'] = {'mode': 'include', 'ids': [1, 'special:notes'], 'ranges': [[3, 5]]}
        item['appearance']['backgroundOpacity'] = 0.35
        self.theme['widgets'] = {'schemaVersion': 1, 'widgets': [item]}
        for target in self.theme['targets']:
            self.theme['targets'][target] = target == 'widgets'
        before = copy.deepcopy(self.theme)
        files, _ = render_theme(self.theme)
        self.assertEqual({'widgets/profile.json'}, set(files))
        self.assertEqual(self.theme['widgets'], json.loads(files['widgets/profile.json']))
        self.assertEqual(before, self.theme)

    def test_old_profiles_fail_instead_of_being_converted(self) -> None:
        for old in ({'profile': 'compact', 'items': []},
                    {'schema_version': 1, 'items': []},
                    {'schemaVersion': 1, 'widgets': [], 'style': {}}):
            with self.subTest(profile=old):
                self.theme['widgets'] = old
                errors = schema_errors(self.theme)
                self.assertTrue(any(error.startswith('widgets: profile:') for error in errors), errors)
                with self.assertRaises(self.model.ValidationError):
                    render_theme(self.theme)

    def test_semantic_validation_runs_without_jsonschema(self) -> None:
        item = self.model.default_widget('clock', 'clock')
        self.theme['widgets'] = {'schemaVersion': 1, 'widgets': [item, copy.deepcopy(item)]}
        with mock.patch.dict(sys.modules, {'jsonschema': None}):
            errors = schema_errors(self.theme)
        self.assertTrue(any('duplicate id' in error for error in errors), errors)

    def test_supplied_widget_profile_is_atomic_during_default_resolution(self) -> None:
        source = copy.deepcopy(self.theme)
        source['widgets'] = {'widgets': []}
        resolved = apply_theme_defaults(source)
        self.assertEqual({'widgets': []}, resolved['widgets'])
        self.assertTrue(schema_errors(resolved))
        source.pop('widgets')
        self.assertEqual(self.model.default_profile(), apply_theme_defaults(source)['widgets'])

    def test_defaults_share_the_same_strict_profile(self) -> None:
        self.assertEqual(self.model.default_profile(), default_widget_profile())
        document = json.loads((THEMES / 'defaults/v1.json').read_text())
        document['widgets'] = {'profile': 'compact', 'profiles': {}}
        self.assertTrue(any(error.startswith('widgets:') for error in defaults_schema_errors(document)))

    def test_picker_count_uses_enabled_new_items(self) -> None:
        profile = self.model.default_profile()
        profile['widgets'] = [self.model.default_widget('clock', 'clock'),
                              self.model.default_widget('notes', 'notes')]
        profile['widgets'][1]['enabled'] = False
        self.theme['widgets'] = profile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'count-test.json').write_text(json.dumps(self.theme))
            with mock.patch('blox_theme.core.builtin_themes_dir', return_value=root), \
                 mock.patch('blox_theme.core.user_theme_library', return_value=root / 'user'):
                entries = list_themes()
        self.assertEqual([1], [entry['preview']['widget_count'] for entry in entries])


if __name__ == '__main__':
    unittest.main()
