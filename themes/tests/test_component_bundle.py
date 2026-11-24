from __future__ import annotations

import copy
import hashlib
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

from themes.lib.blox_theme.component_bundle import (
    export_components, import_components, inspect_components, review_export, review_import, selection,
)
from themes.lib.blox_theme.core import load_theme, widget_model
from themes.lib.blox_theme.portability import PortabilityFailure, _zip_info
from shell.scripts.settings_document import SettingsDocument


class ComponentBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.theme = load_theme('catppuccin-mocha')
        self.settings = SettingsDocument().defaults
        self.data = self.root / 'blox-user'

    def bundle(self, preset='minimal', **kwargs):
        path = self.root / 'theme.blox-theme'
        export_components(self.theme, self.settings, path, preset, source_path=self.source, **kwargs)
        return path

    def rewrite(self, path, transform):
        with zipfile.ZipFile(path) as archive:
            contents = {name: archive.read(name) for name in archive.namelist()}
        transform(contents)
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in contents.items():
                archive.writestr(_zip_info(name), data)

    def test_preset_round_trips_and_custom_selection(self):
        for preset in ('minimal', 'standard', 'full'):
            with self.subTest(preset=preset):
                path = self.root / f'{preset}.blox-theme'
                export_components(self.theme, self.settings, path, preset, wallpaper=False)
                manifest, components, _ = inspect_components(path)
                self.assertEqual(set(selection(preset, wallpaper=False)), set(components))
                other = copy.deepcopy(self.theme); other['wallpaper']['path'] = '/current/wallpaper.png'
                theme, settings, dormant = import_components(path, other, self.settings, self.data)
                self.assertEqual('/current/wallpaper.png', theme['wallpaper']['path'])
                self.assertEqual(self.settings, settings)
                self.assertEqual({}, dormant)
        self.assertEqual(('appearance', 'bar', 'theme-metadata'), selection('custom', {'appearance', 'bar', 'theme-metadata'}))

    def test_archive_label_follows_actual_selection(self):
        minimal = set(selection('minimal'))
        exact = self.root / 'exact.blox-theme'
        export_components(self.theme, self.settings, exact, 'minimal', selected=minimal,
                          source_path=self.source)
        self.assertEqual('minimal', inspect_components(exact)[0]['preset'])
        changed = self.root / 'changed.blox-theme'
        export_components(self.theme, self.settings, changed, 'minimal', wallpaper=False,
                          source_path=self.source)
        self.assertEqual('custom', inspect_components(changed)[0]['preset'])
        custom = self.root / 'custom.blox-theme'
        export_components(self.theme, self.settings, custom, 'custom',
                          selected={'theme-metadata', 'appearance', 'bar'}, wallpaper=False,
                          source_path=self.source)
        self.assertEqual('custom', inspect_components(custom)[0]['preset'])
        self.assertEqual({'theme-metadata', 'appearance', 'bar'}, set(inspect_components(custom)[0]['components']))

    def test_portable_note_configuration_is_kept_and_runtime_data_rejected(self):
        self.settings['widgets'] = {'schemaVersion': 1, 'widgets': [
            widget_model().default_widget('notes', 'notes', {'text': 'PORTABLE_NOTE_SENTINEL'})]}
        self.settings['runtimeStatus'] = 'PRIVATE_STATUS_SENTINEL'
        self.settings['authentication'] = 'PRIVATE_AUTH_SENTINEL'
        # The owner rejects unregistered fields. Remove them after checking that export fails closed.
        with self.assertRaises(ValueError):
            self.bundle('full', wallpaper=False)
        del self.settings['runtimeStatus']; del self.settings['authentication']
        path = self.bundle('full', wallpaper=False)
        with zipfile.ZipFile(path) as archive:
            blob = b''.join(archive.read(name) for name in archive.namelist())
        self.assertIn(b'PORTABLE_NOTE_SENTINEL', blob)
        self.assertNotIn(b'PRIVATE_STATUS_SENTINEL', blob)
        self.assertNotIn(b'PRIVATE_AUTH_SENTINEL', blob)

    def test_selected_wallpaper_requires_asset_and_omission_preserves_current(self):
        self.theme['wallpaper']['path'] = str(self.root / 'missing.png')
        omitted = self.bundle(wallpaper=False)
        current = copy.deepcopy(self.theme); current['wallpaper']['path'] = 'kept.png'
        theme, _, _ = import_components(omitted, current, self.settings, self.data)
        self.assertEqual('kept.png', theme['wallpaper']['path'])
        with self.assertRaisesRegex(PortabilityFailure, 'wallpaper'):
            export_components(self.theme, self.settings, self.root / 'selected.blox-theme', 'minimal')
        wallpaper = self.root / 'image.png'; wallpaper.write_bytes(b'image')
        self.theme['wallpaper']['path'] = str(wallpaper)
        selected = self.root / 'selected.blox-theme'
        export_components(self.theme, self.settings, selected, 'minimal')
        theme, _, _ = import_components(selected, current, self.settings, self.data)
        self.assertEqual(b'image', Path(theme['wallpaper']['path']).read_bytes())
        self.rewrite(selected, lambda files: files.pop(next(n for n in files if n.startswith('assets/wallpaper/'))))
        with self.assertRaises(PortabilityFailure):
            import_components(selected, current, self.settings, self.data)

    def test_exec_bind_reviews_packages_and_rewrites_only_executable_argument(self):
        script = self.root / 'mine.sh'
        script.write_text('#!/bin/sh\necho hello\n')
        self.settings['binds'] = [{'id': 'mine', 'enabled': True, 'key': 'F12',
                                   'modifiers': ['SUPER'], 'action': 'exec',
                                   'arguments': [str(script), '--label', 'two words']}]
        review = review_export(self.theme, self.settings, 'full', wallpaper=False)
        self.assertEqual([str(script)], [entry['path'] for entry in review])
        exported = self.bundle('full', wallpaper=False, approvals={str(script): review[0]['sha256']})
        _, components, files = inspect_components(exported)
        bind = components['binds'][0]
        self.assertEqual(bind['action'], 'exec')
        self.assertEqual(bind['arguments'][1:], ['--label', 'two words'])
        self.assertTrue(bind['arguments'][0].startswith('assets/scripts/'))
        self.assertEqual(files[bind['arguments'][0]], script.read_bytes())
        imported_review = review_import(exported)
        head = imported_review[0]['path']
        _, imported, _ = import_components(exported, self.theme, self.settings, self.data,
                                            approvals={head: imported_review[0]['sha256']})
        imported_bind = imported['binds'][0]
        self.assertTrue(imported_bind['enabled'])
        self.assertEqual(imported_bind['action'], 'exec')
        self.assertEqual(imported_bind['arguments'][1:], ['--label', 'two words'])
        self.assertEqual(Path(imported_bind['arguments'][0]).read_bytes(), script.read_bytes())
        _, refused, _ = import_components(exported, self.theme, self.settings, self.data)
        self.assertFalse(refused['binds'][0]['enabled'])
        self.assertEqual(refused['binds'][0]['arguments'], ['/usr/bin/false'])
        with self.assertRaisesRegex(PortabilityFailure, 'digest'):
            import_components(exported, self.theme, self.settings, self.data, approvals={head: '0' * 64})
        with self.assertRaisesRegex(PortabilityFailure, 'changed'):
            self.bundle('full', wallpaper=False, approvals={str(script): '0' * 64})

    def test_refused_exec_bind_export_disables_command_without_packaging_script(self):
        script = self.root / 'mine.sh'
        script.write_text('#!/bin/sh\necho hello\n')
        self.settings['binds'] = [{'id': 'mine', 'enabled': True, 'key': 'F12',
                                   'modifiers': [], 'action': 'exec', 'arguments': [str(script), '--hello']}]
        exported = self.bundle('full', wallpaper=False)
        _, components, files = inspect_components(exported)
        self.assertFalse(components['binds'][0]['enabled'])
        self.assertEqual(components['binds'][0]['arguments'], ['/usr/bin/false'])
        self.assertFalse(any(name.startswith('assets/scripts/') for name in files))
        _, imported, _ = import_components(exported, self.theme, self.settings, self.data)
        self.assertFalse(imported['binds'][0]['enabled'])
        self.assertNotIn(str(script), imported['binds'][0]['arguments'])

    def test_command_output_script_requires_review_and_round_trips_arguments(self):
        script = self.root / 'widget.sh'
        script.write_text('#!/bin/sh\nprintf "widget output\\n"\n')
        self.settings['widgets'] = {'schemaVersion': 1, 'widgets': [
            widget_model().default_widget('command', 'command-output',
                {'command': [str(script), '--label', 'two words']})]}
        review = review_export(self.theme, self.settings, 'full', wallpaper=False)
        self.assertEqual([str(script)], [entry['path'] for entry in review])
        exported = self.bundle('full', wallpaper=False,
            approvals={str(script): review[0]['sha256']})
        _, components, files = inspect_components(exported)
        item = components['widgets']['widgets'][0]
        self.assertEqual(['--label', 'two words'], item['settings']['command'][1:])
        self.assertEqual(script.read_bytes(), files[item['settings']['command'][0]])
        _, refused, _ = import_components(exported, self.theme, self.settings, self.data)
        self.assertFalse(refused['widgets']['widgets'][0]['enabled'])
        imported_review = review_import(exported)
        _, accepted, _ = import_components(exported, self.theme, self.settings, self.data,
            approvals={entry['path']: entry['sha256'] for entry in imported_review})
        restored = accepted['widgets']['widgets'][0]
        self.assertTrue(restored['enabled'])
        self.assertEqual(['--label', 'two words'], restored['settings']['command'][1:])
        self.assertEqual(script.read_bytes(), Path(restored['settings']['command'][0]).read_bytes())

    def test_action_heads_review_rewrite_and_refusal_preserve_dormant_bindings(self):
        scripts = []
        for name in ('run', 'launch'):
            path = self.root / (name + '.py'); path.write_text('#!/usr/bin/python3\nprint("' + name + '")\n'); scripts.append(path)
        actions = {'left': {'kind': 'run', 'command': [str(scripts[0]), str(scripts[1])],
                   'workingDirectory': '', 'environment': {}, 'timeoutSeconds': 5},
                   'right': {'kind': 'launch', 'command': [str(scripts[1]), 'literal;$(argument)']}}
        widget = widget_model().default_widget('command', 'actions', {'command': ['producer'], 'actions': actions})
        self.settings['widgets'] = {'schemaVersion': 1, 'widgets': [widget]}
        review = review_export(self.theme, self.settings, 'full', wallpaper=False)
        self.assertEqual({entry['path'] for entry in review}, {str(path) for path in scripts})
        approvals = {entry['path']: entry['sha256'] for entry in review}
        exported = self.bundle('full', wallpaper=False, approvals=approvals)
        _, components, files = inspect_components(exported)
        rewritten = components['widgets']['widgets'][0]['settings']['actions']
        for button, script in zip(('left', 'right'), scripts):
            self.assertEqual(files[rewritten[button]['command'][0]], script.read_bytes())
        self.assertEqual(rewritten['left']['command'][1], str(scripts[1]))
        imported = review_import(exported)
        widget_review = next(entry for entry in imported if entry['path'].startswith('widgets.'))
        self.assertEqual(json.loads(widget_review['contents'])['actions'], rewritten)
        accepted = {entry['path']: entry['sha256'] for entry in imported}
        _, result, _ = import_components(exported, self.theme, self.settings, self.data, approvals=accepted)
        restored = result['widgets']['widgets'][0]
        self.assertTrue(restored['enabled'])
        self.assertEqual(restored['settings']['actions']['right']['command'][1], 'literal;$(argument)')
        for button, script in zip(('left', 'right'), scripts):
            self.assertEqual(Path(restored['settings']['actions'][button]['command'][0]).read_bytes(), script.read_bytes())
        accepted.pop(rewritten['right']['command'][0])
        _, refused, _ = import_components(exported, self.theme, self.settings, self.data, approvals=accepted, install_assets=False)
        dormant = refused['widgets']['widgets'][0]
        self.assertFalse(dormant['enabled'])
        self.assertEqual(dormant['settings']['actions']['right'], rewritten['right'])
        scripts[0].write_text('changed')
        with self.assertRaisesRegex(PortabilityFailure, 'changed'):
            export_components(self.theme, self.settings, self.root/'changed.blox-theme', 'full', wallpaper=False, approvals=approvals)
        scripts[0].unlink(); scripts[0].symlink_to(scripts[1])
        with self.assertRaisesRegex(PortabilityFailure, 'symlink'):
            review_export(self.theme, self.settings, 'full', wallpaper=False)

    def test_non_exec_binds_and_command_data_arguments_are_not_script_references(self):
        script = self.root / 'mine.sh'
        script.write_text('#!/bin/sh\necho hello\n')
        self.settings['binds'] = [
            {'id': 'workspace', 'enabled': True, 'key': 'F11', 'modifiers': [],
             'action': 'workspace', 'arguments': [str(script)]},
            {'id': 'echo', 'enabled': True, 'key': 'F12', 'modifiers': [],
             'action': 'exec', 'arguments': ['echo', str(script)]}]
        self.assertEqual(review_export(self.theme, self.settings, 'full', wallpaper=False), [])
        exported = self.bundle('full', wallpaper=False)
        _, components, _ = inspect_components(exported)
        self.assertEqual(components['binds'], self.settings['binds'])

    def test_script_review_approval_refusal_change_missing_and_unsafe(self):
        script = self.root / 'mine.sh'; script.write_text('#!/bin/sh\necho hello\n')
        self.settings['autostart'] = [{'id': 'mine', 'name': 'Mine', 'enabled': True,
                                       'argv': [str(script), '--hello'], 'delaySeconds': 0}]
        review = review_export(self.theme, self.settings, 'full', wallpaper=False)
        self.assertEqual(1, len(review))
        self.assertEqual(script.read_text(), review[0]['contents'])
        self.assertEqual(str(script), review[0]['path'])
        self.assertEqual(script.stat().st_size, review[0]['size'])
        self.assertEqual(hashlib.sha256(script.read_bytes()).hexdigest(), review[0]['sha256'])
        with self.assertRaisesRegex(PortabilityFailure, 'changed'):
            self.bundle('full', wallpaper=False, approvals={str(script): '0' * 64})
        script.write_text('#!/bin/sh\necho changed\n')
        with self.assertRaisesRegex(PortabilityFailure, 'changed'):
            self.bundle('full', wallpaper=False, approvals={str(script): review[0]['sha256']})
        script.write_text(review[0]['contents'])
        refused_path = self.root / 'refused.blox-theme'
        export_components(self.theme, self.settings, refused_path, 'full', wallpaper=False)
        _, refused_components, _ = inspect_components(refused_path)
        self.assertFalse(refused_components['autostart'][0]['enabled'])
        approved = self.bundle('full', wallpaper=False, approvals={str(script): review[0]['sha256']})
        imported_review = review_import(approved)
        self.assertEqual(script.read_text(), imported_review[0]['contents'])
        head = imported_review[0]['path']
        theme, settings, _ = import_components(approved, self.theme, self.settings, self.data,
                                                approvals={head: imported_review[0]['sha256']})
        self.assertEqual('--hello', settings['autostart'][0]['argv'][1])
        self.assertEqual(script.read_bytes(), Path(settings['autostart'][0]['argv'][0]).read_bytes())
        with self.assertRaisesRegex(PortabilityFailure, 'digest'):
            import_components(approved, self.theme, self.settings, self.data, approvals={head: '0' * 64})
        _, refused, _ = import_components(approved, self.theme, self.settings, self.data)
        self.assertFalse(refused['autostart'][0]['enabled'])
        script.unlink()
        with self.assertRaisesRegex(PortabilityFailure, 'cannot read script'):
            review_export(self.theme, self.settings, 'full', wallpaper=False)
        script.symlink_to('/etc/passwd')
        with self.assertRaisesRegex(PortabilityFailure, 'unsafe script'):
            review_export(self.theme, self.settings, 'full', wallpaper=False)

    def test_first_party_installed_scripts_do_not_require_user_script_review(self):
        from themes.lib.blox_theme.core import repository_root
        first_party = repository_root() / 'shell/scripts/widgets/todo-content.sh'
        self.assertTrue(first_party.is_file())
        self.settings['widgets'] = {'schemaVersion': 1, 'widgets': [
            widget_model().default_widget('command', 'todo', {'command': [str(first_party)]})]}
        self.assertEqual([], review_export(self.theme, self.settings, 'full', wallpaper=False))

    def test_system_executable_and_argument_paths_are_not_collected(self):
        transitive = self.root / 'argument.txt'; transitive.write_text('PRIVATE_ARGUMENT_FILE')
        self.settings['autostart'] = [{'id': 'system', 'name': 'System', 'enabled': True,
                                       'argv': ['/usr/bin/printf', str(transitive)], 'delaySeconds': 0}]
        self.assertEqual([], review_export(self.theme, self.settings, 'full', wallpaper=False))
        path = self.bundle('full', wallpaper=False)
        with zipfile.ZipFile(path) as archive:
            self.assertFalse(any(name.startswith('assets/scripts/') for name in archive.namelist()))
            self.assertNotIn(b'PRIVATE_ARGUMENT_FILE', b''.join(archive.read(name) for name in archive.namelist()))

    def test_unknown_full_component_is_dormant(self):
        path = self.bundle('full')
        def add_unknown(files):
            manifest = json.loads(files['manifest.json'])
            data = b'{"futureValue":true}\n'
            name = 'components/future-component.json'
            files[name] = data
            manifest['components'].append('future-component')
            manifest['files'][name] = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            files['manifest.json'] = json.dumps(manifest).encode()
        self.rewrite(path, add_unknown)
        theme, settings, dormant = import_components(path, self.theme, self.settings, self.data)
        self.assertEqual({'future-component': {'futureValue': True}}, dormant)
        self.assertEqual(self.theme['id'], theme['id'])
        self.assertEqual(self.theme['colours'], theme['colours'])
        self.assertEqual(self.settings, settings)
