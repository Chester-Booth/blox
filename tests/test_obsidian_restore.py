"""Restore file events must settle before Obsidian's native theme refresh."""
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from themes.lib.blox_theme import obsidian, runtime, target_preimage
from themes.lib.blox_theme.apply_owners import ThemeTargetOwner


class ObsidianRestoreTimingTests(unittest.TestCase):
    def exercise_restore(self, settle_seconds):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            vault = root / 'vault'
            (vault / '.obsidian').mkdir(parents=True)
            appearance = vault / '.obsidian/appearance.json'
            original = b'{"cssTheme":"Blox generated","baseFontSize":19}\n'
            appearance.write_bytes(original)
            registry = root / 'config/obsidian/obsidian.json'
            registry.parent.mkdir(parents=True)
            registry.write_text(json.dumps({'vaults': {'fixture': {'path': str(vault), 'open': True}}}))
            native = {'theme': 'Blox generated'}
            seen = threading.Event()
            delivered = threading.Event()
            stopped = threading.Event()
            baseline = (appearance.stat().st_ino, appearance.stat().st_mtime_ns)
            commands = []

            # Watch the actual restored file inode, then deliver its captured
            # setting asynchronously as Obsidian's vault watcher does.
            def watcher():
                while not stopped.wait(0.001):
                    try:
                        info = appearance.stat()
                        if (info.st_ino, info.st_mtime_ns) == baseline:
                            continue
                        document = json.loads(appearance.read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        continue
                    seen.set()
                    time.sleep(0.02)
                    native['theme'] = document.get('cssTheme', '')
                    delivered.set()
                    return

            def process(command, **kwargs):
                commands.append(command)
                self.assertTrue(seen.wait(1), 'No real pre-image file event reached the watcher')
                if 'theme:set' in command:
                    native['theme'] = command[-1][5:]
                    reply = 'Switched to default theme' if native['theme'] == '' else 'Switched to: ' + native['theme']
                else:
                    self.assertTrue(delivered.wait(1), 'The appearance watcher never delivered its queued setting')
                    reply = native['theme'] or '(default)'
                kwargs['stdout'].write((reply + '\n').encode())
                kwargs['stdout'].flush()
                result = mock.Mock()
                result.poll.return_value = 0
                return result

            environment = {'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_STATE_HOME': str(root / 'state'),
                           'BLOX_OBSIDIAN_VAULT': 'fixture'}
            with mock.patch.dict(os.environ, environment), \
                 mock.patch.object(obsidian, '_obsidian_is_running', return_value=True), \
                 mock.patch.object(obsidian, 'OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS', settle_seconds), \
                 mock.patch.object(obsidian.subprocess, 'Popen', side_effect=process), \
                 mock.patch.object(obsidian, '_stop_obsidian_cli'), \
                 mock.patch('themes.lib.blox_theme.apply_owners._restore_snapshot'):
                owner = ThemeTargetOwner('obsidian', 'appearance', root / 'theme.json', {})
                image = {'external': target_preimage.capture('obsidian')}
                thread = threading.Thread(target=watcher)
                thread.start()
                try:
                    if settle_seconds:
                        owner.restore(image)
                        self.assertEqual(native['theme'], 'Blox generated')
                        self.assertEqual(appearance.read_bytes(), original)
                        self.assertEqual([c[-1] for c in commands], ['name=', 'theme', 'name=Blox generated', 'theme'])
                    else:
                        with self.assertRaisesRegex(obsidian.ObsidianFailure, 'unexpected reply: Blox generated'):
                            owner.restore(image)
                finally:
                    stopped.set()
                    thread.join(timeout=2)
                    self.assertFalse(thread.is_alive())

    def test_restore_settles_preimage_watcher_before_verified_native_refresh(self):
        self.exercise_restore(0.08)

    def test_unsettled_watcher_replay_is_rejected_by_native_query(self):
        self.exercise_restore(0)


if __name__ == '__main__':
    unittest.main()
