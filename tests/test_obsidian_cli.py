"""Native Obsidian state can differ from its saved appearance selection."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from themes.lib.blox_theme import obsidian


class LiveObsidianCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        vault = Path(self.temporary.name)
        (vault / '.obsidian').mkdir()
        self.paths = obsidian.safe_paths(obsidian.ObsidianVault('fixture', vault))
        self.paths.appearance.write_text('{"cssTheme":"Blox generated","baseFontSize":19}')
        self.commands = []

    def process_factory(self, replies, persistent=False):
        def start(command, **kwargs):
            self.commands.append(command)
            kwargs['stdout'].write((replies[len(self.commands) - 1] + '\n').encode())
            kwargs['stdout'].flush()
            process = mock.Mock()
            process.poll.return_value = None if persistent else 0
            return process
        return start

    def test_empty_native_selection_uses_unquoted_argv_and_query_despite_saved_blox_theme(self):
        saved = self.paths.appearance.read_bytes()
        with mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                ['Switched to default theme', '(default)'], persistent=True)), \
             mock.patch.object(obsidian, '_stop_obsidian_cli') as stop:
            obsidian._run_live_theme_set(self.paths, '')
        self.assertEqual(self.commands, [
            ['obsidian', 'vault=fixture', 'theme:set', 'name='],
            ['obsidian', 'vault=fixture', 'theme']])
        self.assertEqual(self.paths.appearance.read_bytes(), saved)
        self.assertEqual(stop.call_count, 2)

    def generated_package(self):
        root = Path(self.temporary.name) / 'state'
        source = root / 'current/obsidian'
        source.mkdir(parents=True)
        (source / 'manifest.json').write_text(json.dumps({'name': obsidian.OBSIDIAN_THEME_NAME}))
        (source / 'theme.css').write_text('body { color: #abcdef; }\n')
        return root

    def test_publish_persists_verified_live_theme_when_obsidian_save_is_deferred(self):
        self.paths.appearance.write_text('{"cssTheme":"Personal","baseFontSize":19}')
        root = self.generated_package()
        with mock.patch.object(obsidian, 'discover_vault', return_value=self.paths.vault), \
             mock.patch.object(obsidian, '_obsidian_is_running', return_value=True), \
             mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                 ['Switched to: Blox generated', 'Blox generated'])), \
             mock.patch.object(obsidian, '_stop_obsidian_cli'):
            self.assertEqual(obsidian.publish(root, lambda command: None, real_cli=True), self.paths.vault.path)
        self.assertEqual(json.loads(self.paths.appearance.read_text()),
                         {'cssTheme': 'Blox generated', 'baseFontSize': 19})
        self.assertEqual(self.paths.stylesheet.read_bytes(), (root / 'current/obsidian/theme.css').read_bytes())
        integration = obsidian._load_integration(root)
        self.assertEqual(integration['previous_css_theme'], {'present': True, 'value': 'Personal'})
        self.assertEqual(self.commands[-1][-1], 'theme')

    def test_failed_native_query_does_not_persist_desired_selection(self):
        self.paths.appearance.write_text('{"cssTheme":"Personal","baseFontSize":19}')
        before = self.paths.appearance.read_bytes()
        root = self.generated_package()
        with mock.patch.object(obsidian, 'discover_vault', return_value=self.paths.vault), \
             mock.patch.object(obsidian, '_obsidian_is_running', return_value=True), \
             mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                 ['Switched to: Blox generated', 'Personal'])), \
             mock.patch.object(obsidian, '_stop_obsidian_cli'):
            with self.assertRaisesRegex(obsidian.ObsidianFailure, 'unexpected reply'):
                obsidian.publish(root, lambda command: None, real_cli=True)
        self.assertEqual(self.paths.appearance.read_bytes(), before)
        self.assertFalse(self.paths.package.exists())
        self.assertIsNone(obsidian._load_integration(root))

    def test_publish_cleanup_preserves_newer_saved_selection_and_other_fields(self):
        self.paths.appearance.write_text('{"cssTheme":"Personal","baseFontSize":19}')
        root = self.generated_package()
        process = self.process_factory(['Switched to: Blox generated', 'Blox generated'])
        def select(command, **kwargs):
            if command[-1] == 'theme':
                self.paths.appearance.write_text('{"cssTheme":"New personal choice","baseFontSize":22}')
            return process(command, **kwargs)
        with mock.patch.object(obsidian, 'discover_vault', return_value=self.paths.vault), \
             mock.patch.object(obsidian, '_obsidian_is_running', return_value=True), \
             mock.patch.object(obsidian.subprocess, 'Popen', side_effect=select), \
             mock.patch.object(obsidian, '_stop_obsidian_cli'):
            with self.assertRaisesRegex(obsidian.ObsidianSelectionConflict, 'preserving the newer choice'):
                obsidian.publish(root, lambda command: None, real_cli=True)
        self.assertEqual(json.loads(self.paths.appearance.read_text()),
                         {'cssTheme': 'New personal choice', 'baseFontSize': 22})
        self.assertFalse(self.paths.package.exists())
        self.assertIsNone(obsidian._load_integration(root))

    def test_managed_publish_preserves_selection_changed_during_native_cleanup(self):
        self.paths.appearance.write_text('{"cssTheme":"Personal","baseFontSize":19}')
        root = self.generated_package()
        with mock.patch.object(obsidian, 'discover_vault', return_value=self.paths.vault), \
             mock.patch.object(obsidian, '_obsidian_is_running', return_value=True), \
             mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                 ['Switched to: Blox generated', 'Blox generated'])), \
             mock.patch.object(obsidian, '_stop_obsidian_cli'):
            obsidian.publish(root, lambda command: None, real_cli=True)
        original_css = self.paths.stylesheet.read_bytes()
        original_integration = obsidian.obsidian_integration_path(root).read_bytes()
        (root / 'current/obsidian/theme.css').write_text('body { color: #123456; }\n')
        native = {'theme': 'Blox generated', 'selections': 0}
        def process(command, **kwargs):
            if 'theme:set' in command:
                native['theme'] = command[-1][5:]
                if native['theme'] == 'Blox generated':
                    native['selections'] += 1
                reply = 'Switched to: ' + native['theme'] if native['theme'] else 'Switched to default theme'
            elif native['theme'] == 'Blox generated' and native['selections'] == 1:
                reply = 'Previous native theme'
            else:
                if native['theme'] == 'Blox generated' and native['selections'] == 2:
                    self.paths.appearance.write_text('{"cssTheme":"New personal choice","baseFontSize":22}')
                reply = native['theme'] or '(default)'
            kwargs['stdout'].write((reply + '\n').encode())
            kwargs['stdout'].flush()
            child = mock.Mock()
            child.poll.return_value = 0
            return child
        with mock.patch.object(obsidian, 'discover_vault', return_value=self.paths.vault), \
             mock.patch.object(obsidian, '_obsidian_is_running', return_value=True), \
             mock.patch.object(obsidian.subprocess, 'Popen', side_effect=process), \
             mock.patch.object(obsidian, '_stop_obsidian_cli'), \
             mock.patch.object(obsidian, 'OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS', 0), \
             mock.patch.object(obsidian, 'OBSIDIAN_PACKAGE_APPLY_SETTLE_SECONDS', 0):
            with self.assertRaisesRegex(obsidian.ObsidianSelectionConflict, 'unexpected reply.*cleanup:'):
                obsidian.publish(root, lambda command: None, real_cli=True)
        self.assertEqual(json.loads(self.paths.appearance.read_text()),
                         {'cssTheme': 'New personal choice', 'baseFontSize': 22})
        self.assertEqual(self.paths.stylesheet.read_bytes(), original_css)
        self.assertEqual(obsidian.obsidian_integration_path(root).read_bytes(), original_integration)

    def test_nonempty_selection_requires_native_query_even_if_saved_file_matches(self):
        with mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                ['Switched to: Blox generated', '(default)'])), \
             mock.patch.object(obsidian, '_stop_obsidian_cli') as stop:
            with self.assertRaisesRegex(obsidian.ObsidianFailure, 'unexpected reply'):
                obsidian._run_live_theme_set(self.paths, 'Blox generated')
        self.assertEqual(self.commands[0][-1], 'name=Blox generated')
        self.assertEqual(json.loads(self.paths.appearance.read_text())['cssTheme'], 'Blox generated')
        self.assertEqual(stop.call_count, 2)

    def test_default_native_query_succeeds_with_saved_absent_or_empty_selection(self):
        for appearance in ({'baseFontSize': 19}, {'cssTheme': '', 'baseFontSize': 19}):
            with self.subTest(appearance=appearance):
                self.commands.clear()
                self.paths.appearance.write_text(json.dumps(appearance))
                with mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                        ['Switched to default theme', '(default)'])), \
                     mock.patch.object(obsidian, '_stop_obsidian_cli'):
                    obsidian._run_live_theme_set(self.paths, '')
                self.assertEqual(json.loads(self.paths.appearance.read_text()), appearance)

    def test_rejected_setter_never_succeeds_from_matching_saved_file(self):
        with mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                ['Error: vault not found'])), mock.patch.object(obsidian, '_stop_obsidian_cli') as stop:
            with self.assertRaisesRegex(obsidian.ObsidianFailure, 'vault not found'):
                obsidian._run_live_theme_set(self.paths, 'Blox generated')
        self.assertEqual(len(self.commands), 1)
        stop.assert_called_once()

    def test_reply_written_at_process_exit_is_read_before_rejection(self):
        def start(command, **kwargs):
            self.commands.append(command)
            reply = 'Switched to default theme' if 'theme:set' in command else '(default)'
            def poll():
                kwargs['stdout'].write((reply + '\n').encode())
                kwargs['stdout'].flush()
                return 0
            process = mock.Mock()
            process.poll.side_effect = poll
            return process
        with mock.patch.object(obsidian.subprocess, 'Popen', side_effect=start), \
             mock.patch.object(obsidian, '_stop_obsidian_cli'):
            obsidian._run_live_theme_set(self.paths, '')
        self.assertEqual(len(self.commands), 2)

    def test_persistent_unconfirmed_reply_times_out_and_stops_only_its_helper(self):
        with mock.patch.object(obsidian.subprocess, 'Popen', side_effect=self.process_factory(
                ['No selection confirmation'], persistent=True)), \
             mock.patch.object(obsidian.time, 'monotonic', side_effect=[0, 0, 9]), \
             mock.patch.object(obsidian.time, 'sleep'), \
             mock.patch.object(obsidian, '_stop_obsidian_cli') as stop:
            with self.assertRaisesRegex(obsidian.ObsidianFailure, 'did not confirm'):
                obsidian._run_live_theme_set(self.paths, '')
        stop.assert_called_once()


if __name__ == '__main__':
    unittest.main()
