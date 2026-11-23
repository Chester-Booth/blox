"""Actual application publication and cold recovery in isolated user roots."""
import json
import os
import unittest
from unittest import mock

from themes.tests.test_apply_owners import ApplyOwnersTests as _ApplyFixture
from themes.lib.blox_theme import runtime, target_preimage
from themes.lib.blox_theme.apply_coordinator import ApplyError
from themes.lib.blox_theme.apply_owners import create_apply, open_existing_apply


class EditorPublicationTests(unittest.TestCase):
    setUp = _ApplyFixture.setUp
    def publication_round_trip(self, target):
        with mock.patch.dict(os.environ, {
            'VSCODE_EXTENSIONS': str(self.root / 'code-extensions'),
            'CURSOR_EXTENSIONS': str(self.root / 'cursor-extensions'),
            'T3CODE_HOME': str(self.root / 't3'),
        }), mock.patch.object(runtime.shutil, 'which', return_value='/fixture/editor'):
            self.assertTrue(self.settings.set('targets.' + target + '.enabled', True,
                                             self.settings.get().revision).ok)
            settings = (runtime.editor_settings_path(target) if target in ('code', 'cursor_editor')
                        else runtime.zed_paths()[1] if target == 'zed' else runtime.t3code_paths()[1])
            settings.parent.mkdir(parents=True, exist_ok=True)
            settings.write_text('{"personal": "preserve"}\n')
            before = target_preimage.capture(target)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            result = coordinator.apply(request)
            self.assertEqual(result['code'], 'ok', result)
            selected = json.loads(settings.read_text())
            self.assertEqual(selected['personal'], 'preserve')
            if target in ('code', 'cursor_editor'):
                package = runtime.editor_extensions_path(target) / runtime.EDITOR_EXTENSION_DIR
                self.assertTrue((package / 'package.json').is_file())
                self.assertTrue((package / runtime.EDITOR_THEME_RELATIVE_PATH).is_file())
                self.assertIn('workbench.colorTheme', selected)
            elif target == 'zed':
                self.assertTrue(runtime.zed_paths()[0].is_file())
                self.assertIn('theme', selected)
            else:
                self.assertTrue(runtime.t3code_paths()[0].is_file())
                self.assertEqual(selected['defaultTheme'], runtime.T3CODE_THEME_ID)
            self.assertFalse(any(command[0] in ('code', 'cursor', 'zed', 'zeditor', 'systemctl')
                                 for command in self.commands))
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertEqual(reopened.roll_back()['code'], 'rolled-back')
            self.assertEqual(target_preimage.capture(target)['files'], before['files'])
            # A later Apply must also restore an already published package and selection.
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            self.assertEqual(coordinator.apply(request)['code'], 'ok')
            coordinator.finish()
            published_before = target_preimage.capture(target)
            coordinator, request = create_apply('catppuccin-latte', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            self.assertEqual(coordinator.apply(request)['code'], 'ok')
            self.assertNotEqual(target_preimage.capture(target)['files'], published_before['files'])
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertEqual(reopened.roll_back()['code'], 'rolled-back')
            self.assertEqual(target_preimage.capture(target)['files'], published_before['files'])

    def test_code_publication_and_cold_rollback(self):
        self.publication_round_trip('code')

    def test_cursor_editor_publication_and_cold_rollback(self):
        self.publication_round_trip('cursor_editor')

    def test_zed_publication_and_cold_rollback(self):
        self.publication_round_trip('zed')

    def test_t3code_publication_and_cold_rollback(self):
        self.publication_round_trip('t3code')

    def test_changed_published_theme_blocks_cold_rollback(self):
        with mock.patch.dict(os.environ, {'T3CODE_HOME': str(self.root / 't3')}):
            self.settings.set('targets.t3code.enabled', True, self.settings.get().revision)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            self.assertEqual(coordinator.apply(request)['code'], 'ok')
            published = runtime.t3code_paths()[0]
            published.write_bytes(b'personal replacement')
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertFalse(reopened.status()['actions']['rollBack'])
            self.assertEqual(published.read_bytes(), b'personal replacement')

    def test_foreign_package_files_are_preserved_before_apply(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            package = runtime.editor_extensions_path('code') / runtime.EDITOR_EXTENSION_DIR
            package.mkdir(parents=True)
            (package / 'personal').write_bytes(b'keep this')
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            with self.assertRaisesRegex(ApplyError, 'foreign or unsafe'):
                coordinator.apply(request)
            self.assertEqual((package / 'personal').read_bytes(), b'keep this')
            self.assertFalse((package / 'package.json').exists())

    def test_owned_dotfiles_link_publishes_and_cold_rollback_preserves_link(self):
        for target in ('code', 'cursor_editor'):
            with self.subTest(target=target), mock.patch.dict(os.environ, {
                'VSCODE_EXTENSIONS': str(self.root / 'code-extensions'),
                'CURSOR_EXTENSIONS': str(self.root / 'cursor-extensions'),
            }):
                self.settings.set('targets.' + target + '.enabled', True, self.settings.get().revision)
                external = self.root / ('dotfiles-' + target)
                original = b'{"personal": true}\n'
                external.write_bytes(original)
                external.chmod(0o640)
                settings = runtime.editor_settings_path(target)
                settings.parent.mkdir(parents=True, exist_ok=True)
                literal = str(external) if target == 'code' else os.path.relpath(external, settings.parent)
                settings.symlink_to(literal)
                link_inode = settings.lstat().st_ino
                coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                    hyprland_runner=self.hyprland_runner)
                self.assertEqual(coordinator.apply(request)['code'], 'ok')
                self.assertIn('workbench.colorTheme', json.loads(external.read_text()))
                self.assertEqual(settings.lstat().st_ino, link_inode)
                reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
                self.assertTrue(reopened.status()['actions']['rollBack'])
                self.assertEqual(reopened.roll_back()['code'], 'rolled-back')
                self.assertEqual(external.read_bytes(), original)
                self.assertEqual(external.stat().st_mode & 0o777, 0o640)
                self.assertEqual(settings.lstat().st_ino, link_inode)
                self.assertEqual(os.readlink(settings), literal)
                self.settings.set('targets.' + target + '.enabled', False, self.settings.get().revision)

    def test_dotfiles_link_or_referent_drift_blocks_cold_rollback(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            external = self.root / 'dotfiles'
            external.write_bytes(b'{"personal": true}')
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            settings.symlink_to(external)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            self.assertEqual(coordinator.apply(request)['code'], 'ok')
            applied = external.read_bytes()
            external.write_bytes(b'{"personal": "changed"}')
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertFalse(reopened.status()['actions']['rollBack'])
            with self.assertRaises(ApplyError):
                reopened.roll_back()
            self.assertEqual(external.read_bytes(), b'{"personal": "changed"}')
            external.write_bytes(applied)
            replacement = self.root / 'other-dotfiles'
            replacement.write_bytes(b'{"other": true}')
            settings.unlink()
            settings.symlink_to(replacement)
            self.assertFalse(reopened.status()['actions']['rollBack'])
            with self.assertRaises(ApplyError):
                reopened.roll_back()
            self.assertEqual(replacement.read_bytes(), b'{"other": true}')
            self.assertEqual(external.read_bytes(), applied)

    def test_unsafe_settings_links_are_rejected_before_publication(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            directory = self.root / 'directory'
            directory.mkdir()
            for destination in (self.root / 'missing', directory):
                with self.subTest(destination=destination):
                    settings.symlink_to(destination)
                    with self.assertRaises(ApplyError):
                        target_preimage.capture('code')
                    settings.unlink()
            external = self.root / 'dotfiles'
            external.write_bytes(b'{"personal": true}')
            redirected = self.root / 'redirected'
            redirected.symlink_to(self.root, target_is_directory=True)
            settings.symlink_to(redirected / external.name)
            with self.assertRaisesRegex(ApplyError, 'unsafe or missing'):
                target_preimage.capture('code')
            self.assertEqual(external.read_bytes(), b'{"personal": true}')

    def publication_boundary_link_change(self, change, *, before_local=False):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            original = self.root / 'original-dotfiles'
            other = self.root / 'other-dotfiles'
            original.write_bytes(b'{"personal": "original"}')
            other.write_bytes(b'{"personal": "other"}')
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            settings.symlink_to(original)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            publish = runtime.publish_editor_target
            changed_inode = []

            def retarget_at_publication(root, target, **kwargs):
                if change == 'contents':
                    original.write_bytes(b'{"personal": "newer contents"}')
                else:
                    settings.unlink()
                    settings.symlink_to(other if change == 'retarget' else original)
                changed_inode.append(settings.lstat().st_ino)
                return publish(root, target, **kwargs)

            if before_local:
                apply_targets = coordinator._apply_targets
                def retarget_before_local(*args):
                    settings.unlink()
                    settings.symlink_to(other)
                    changed_inode.append(settings.lstat().st_ino)
                    return apply_targets(*args)
                interception = mock.patch.object(coordinator, '_apply_targets', side_effect=retarget_before_local)
            else:
                interception = mock.patch.object(runtime, 'publish_editor_target', side_effect=retarget_at_publication)
            with interception:
                result = coordinator.apply(request)
            self.assertNotEqual(result['code'], 'ok', result)
            self.assertEqual(other.read_bytes(), b'{"personal": "other"}')
            self.assertEqual(original.read_bytes(), b'{"personal": "newer contents"}'
                             if change == 'contents' else b'{"personal": "original"}')
            self.assertEqual(settings.lstat().st_ino, changed_inode[0])
            self.assertEqual(os.readlink(settings), str(other if change == 'retarget' else original))
            package = runtime.editor_extensions_path('code') / runtime.EDITOR_EXTENSION_DIR
            self.assertFalse(package.exists())
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertFalse(reopened.status()['actions']['rollBack'])

    def test_publication_rejects_postcapture_link_retarget_without_writes(self):
        self.publication_boundary_link_change('retarget')

    def test_publication_rejects_identical_target_replacement_link(self):
        self.publication_boundary_link_change('replace')

    def test_publication_rejects_newer_referent_contents_before_package_writes(self):
        self.publication_boundary_link_change('contents')

    def test_durable_image_rejects_retarget_before_local_capture(self):
        self.publication_boundary_link_change('retarget', before_local=True)

    def test_held_parent_fd_prevents_postguard_redirected_settings_write(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            dotfiles = self.root / 'dotfiles'
            dotfiles.mkdir()
            original = dotfiles / 'settings.json'
            original.write_bytes(b'{"personal": "original"}')
            other = self.root / 'other-dotfiles'
            other.mkdir()
            other_settings = other / 'settings.json'
            other_settings.write_bytes(b'{"personal": "foreign"}')
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            settings.symlink_to(original)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            install = runtime.install_editor_extension
            moved = self.root / 'captured-dotfiles'
            def redirect_parent_after_guard(*args, **kwargs):
                dotfiles.rename(moved)
                dotfiles.symlink_to(other, target_is_directory=True)
                return install(*args, **kwargs)
            with mock.patch.object(runtime, 'install_editor_extension', side_effect=redirect_parent_after_guard):
                with self.assertRaises(ApplyError):
                    coordinator.apply(request)
            self.assertEqual(other_settings.read_bytes(), b'{"personal": "foreign"}')
            self.assertIn('workbench.colorTheme', json.loads((moved / 'settings.json').read_text()))
            self.assertTrue(dotfiles.is_symlink())
            self.assertEqual(os.readlink(settings), str(original))

    def test_postguard_link_retarget_retains_honest_afterwrite_conflict(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            original = self.root / 'captured-settings'
            original.write_bytes(b'{"personal": "captured"}')
            other = self.root / 'foreign-settings'
            other.write_bytes(b'{"personal": "foreign"}')
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            settings.symlink_to(original)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            install = runtime.install_editor_extension
            replacement_inode = []
            def retarget_after_guard(*args, **kwargs):
                result = install(*args, **kwargs)
                settings.unlink()
                settings.symlink_to(other)
                replacement_inode.append(settings.lstat().st_ino)
                return result
            with mock.patch.object(runtime, 'install_editor_extension', side_effect=retarget_after_guard):
                with self.assertRaisesRegex(ApplyError, 'restore incomplete'):
                    coordinator.apply(request)
            self.assertIn('workbench.colorTheme', json.loads(original.read_text()))
            self.assertEqual(other.read_bytes(), b'{"personal": "foreign"}')
            self.assertEqual(settings.lstat().st_ino, replacement_inode[0])
            self.assertEqual(os.readlink(settings), str(other))
            # External writes happened. The retained receipt must not claim restoration.
            dfd, fd = coordinator._lock()
            try:
                record = coordinator._read(dfd)
            finally:
                coordinator._unlock(dfd, fd)
            self.assertEqual(record['phase'], 'restoring')
            self.assertTrue(record['restoreErrors'])
            self.assertFalse(record['targets']['code'].get('publicationConflict', False))

    def test_regular_settings_cannot_be_retargeted_to_uncaptured_link(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            settings.write_bytes(b'{"personal": "captured"}')
            other = self.root / 'other-settings'
            other.write_bytes(b'{"personal": "foreign"}')
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            publish = runtime.publish_editor_target
            def replace_at_boundary(root, target, **kwargs):
                settings.unlink()
                settings.symlink_to(other)
                return publish(root, target, **kwargs)
            with mock.patch.object(runtime, 'publish_editor_target', side_effect=replace_at_boundary):
                result = coordinator.apply(request)
            self.assertNotEqual(result['code'], 'ok')
            self.assertEqual(other.read_bytes(), b'{"personal": "foreign"}')
            self.assertTrue(settings.is_symlink())
            self.assertFalse((runtime.editor_extensions_path('code') / runtime.EDITOR_EXTENSION_DIR).exists())

    def test_pending_cold_recovery_preserves_competing_referent_edit(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            referent = self.root / 'dotfiles-settings'
            referent.write_bytes(b'{"personal": "captured"}')
            settings = runtime.editor_settings_path('code')
            settings.parent.mkdir(parents=True)
            settings.symlink_to(referent)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            def crash_before_publication(*args, **kwargs):
                referent.write_bytes(b'{"personal": "newer edit"}')
                raise KeyboardInterrupt('simulated crash before publication')
            with mock.patch.object(runtime, 'publish_editor_target', side_effect=crash_before_publication):
                with self.assertRaises(KeyboardInterrupt):
                    coordinator.apply(request)
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            with self.assertRaises(ApplyError):
                reopened.recover()
            self.assertEqual(referent.read_bytes(), b'{"personal": "newer edit"}')
            self.assertTrue(settings.is_symlink())
            self.assertFalse((runtime.editor_extensions_path('code') / runtime.EDITOR_EXTENSION_DIR).exists())

    def test_malformed_linked_settings_preimage_is_rejected(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            image = target_preimage.capture('code')
            image['files'] = []
            with self.assertRaises(ApplyError):
                target_preimage.validate('code', image)

    def test_combined_code_cursor_status_and_exact_cold_rollback(self):
        with mock.patch.dict(os.environ, {
            'VSCODE_EXTENSIONS': str(self.root / 'code-extensions'),
            'CURSOR_EXTENSIONS': str(self.root / 'cursor-extensions'),
        }):
            for target in ('code', 'cursor_editor'):
                self.settings.set('targets.' + target + '.enabled', True, self.settings.get().revision)
            for theme in ('catppuccin-mocha', 'catppuccin-latte'):
                before = {target: target_preimage.capture(target) for target in ('code', 'cursor_editor')}
                coordinator, request = create_apply(theme, run_command=self.runner,
                                                    hyprland_runner=self.hyprland_runner)
                self.assertEqual(coordinator.apply(request)['code'], 'ok')
                reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
                self.assertTrue(reopened.status()['actions']['rollBack'])
                self.assertEqual(reopened.roll_back()['code'], 'rolled-back')
                for target in before:
                    self.assertEqual(target_preimage.capture(target)['files'], before[target]['files'])
                # Keep one publication so the next pass starts with both existing records.
                coordinator, request = create_apply(theme, run_command=self.runner,
                                                    hyprland_runner=self.hyprland_runner)
                self.assertEqual(coordinator.apply(request)['code'], 'ok')
                coordinator.finish()

    def test_combined_editor_record_drift_blocks_rollback(self):
        with mock.patch.dict(os.environ, {
            'VSCODE_EXTENSIONS': str(self.root / 'code-extensions'),
            'CURSOR_EXTENSIONS': str(self.root / 'cursor-extensions'),
        }):
            for target in ('code', 'cursor_editor'):
                self.settings.set('targets.' + target + '.enabled', True, self.settings.get().revision)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            self.assertEqual(coordinator.apply(request)['code'], 'ok')
            integration = runtime._load_editor_integration(runtime.state_dir())
            integration['editors']['cursor_editor']['last']['workbench.colorTheme'] = 'personal replacement'
            runtime._save_editor_integration(runtime.state_dir(), integration)
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertFalse(reopened.status()['actions']['rollBack'])
            with self.assertRaises(ApplyError):
                reopened.roll_back()
            self.assertEqual(runtime._load_editor_integration(runtime.state_dir()), integration)

    def test_rollback_preserves_newer_unselected_editor_record(self):
        with mock.patch.dict(os.environ, {'VSCODE_EXTENSIONS': str(self.root / 'extensions')}):
            self.settings.set('targets.code.enabled', True, self.settings.get().revision)
            coordinator, request = create_apply('catppuccin-mocha', run_command=self.runner,
                                                hyprland_runner=self.hyprland_runner)
            self.assertEqual(coordinator.apply(request)['code'], 'ok')
            integration = runtime._load_editor_integration(runtime.state_dir())
            other = {'settings_path': str(runtime.editor_settings_path('cursor_editor')),
                     'keys': {}, 'last': {'workbench.colorTheme': 'personal replacement'}}
            integration['editors']['cursor_editor'] = other
            runtime._save_editor_integration(runtime.state_dir(), integration)
            reopened = open_existing_apply(run_command=self.runner, hyprland_runner=self.hyprland_runner)
            self.assertTrue(reopened.status()['actions']['rollBack'])
            self.assertEqual(reopened.roll_back()['code'], 'rolled-back')
            self.assertEqual(runtime._load_editor_integration(runtime.state_dir()),
                             {'schema_version': 1, 'editors': {'cursor_editor': other}})



del _ApplyFixture
