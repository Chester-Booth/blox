"""Drain real Settings preview subprocesses before a durable Apply handoff."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from themes.lib.blox_theme.core import load_theme

REPOSITORY = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('quickshell'), 'quickshell is required for the real preview process proof')
class SettingsHyprlandPreviewHandoffTests(unittest.TestCase):
    def run_handoff(self, fail_restore=False, retained_preview=False):
        with tempfile.TemporaryDirectory(prefix='blox-preview-handoff-') as temporary:
            root = Path(temporary)
            for name in ('config', 'state', 'data', 'bin'):
                (root / name).mkdir(mode=0o700)
            for name in ('modules', 'services', 'shared'):
                (root / name).symlink_to(REPOSITORY / 'shell' / name, target_is_directory=True)
            compositor = root / 'compositor.json'
            options = {key: '1' for key in ('general:border_size', 'general:gaps_in', 'general:gaps_out',
                'general:col.active_border', 'general:col.inactive_border', 'decoration:rounding',
                'decoration:inactive_opacity', 'decoration:shadow:color')}
            compositor.write_text(json.dumps({'options': options, 'batches': [], 'committed': False}))
            preview_journal = root / 'preview.json'
            fake = root / 'bin/hyprctl'
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
path=Path(os.environ['BLOX_FAKE_COMPOSITOR']); state=json.loads(path.read_text()); args=sys.argv[1:]
if args[0]=='status': print('{"configProvider":"legacy"}')
elif args[0]=='getoption': print(json.dumps({'set':True,'css':state['options'][args[1]]}))
elif args[0]=='--batch':
    if not state['batches']: time.sleep(.25)
    if state['batches'] and os.environ.get('BLOX_FAIL_RESTORE')=='1':
        print('mock compositor restore refused',file=sys.stderr); sys.exit(1)
    values={}
    for command in args[1].split(';'):
        _,key,value=command.strip().split(' ',2); values[key]=value
    state['options'].update(values); state['batches'].append(values); path.write_text(json.dumps(state)); print('ok')
else: sys.exit(2)
''')
            fake.chmod(0o700)
            commit = root / 'commit.py'
            commit.write_text('''import json,os
from pathlib import Path
path=Path(os.environ['BLOX_FAKE_COMPOSITOR']); state=json.loads(path.read_text())
state['options']={key:'42' for key in state['options']};state['committed']=True;path.write_text(json.dumps(state))
''')
            _, theme = load_theme('catppuccin-mocha')
            theme['targets'] = {key: key == 'hyprland' for key in theme['targets']}
            source = json.dumps(theme)
            qml = root / 'shell.qml'
            qml.write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules
Scope {
    id: fixture
    QtObject { id: host; property string scriptRoot: "''' + str(REPOSITORY / 'shell/scripts') + '''"; property string errorMessage: "" }
    SettingsHyprlandPreview { id: preview; host: host }
    Timer { interval: 10; running: true; onTriggered: { preview.preview(''' + source + '''); drain.start(); } }
    Timer {
        id: drain; interval: 20
        onTriggered: {
            preview.suspended = true;
            if (!preview.restoreFor("settings-apply")) { console.error("HANDOFF FAIL: in-flight process was not drained"); Qt.quit(); }
            preview.preview(''' + source + ''');
        }
    }
    Connections {
        target: preview
        function onOperationFinished(operation, successful, reason) {
            if (operation !== "restore" || reason !== "settings-apply") return;
            if (!successful) { console.log("HANDOFF RESTORE REFUSED"); Qt.quit(); return; }
            if (preview.transactionActive) { console.error("HANDOFF FAIL: old preview still active"); Qt.quit(); return; }
            commit.running = true;
        }
    }
    Process {
        id: commit; command: ["python3", "''' + str(commit) + '''"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 || preview.restoreFor("close")) { console.error("HANDOFF FAIL: close would restore old compositor"); Qt.quit(); return; }
            preview.preview(''' + source + ''');
            finish.start();
        }
    }
    Timer { id: finish; interval: 150; onTriggered: { console.log("HANDOFF PASS"); Qt.quit(); } }
    Timer { interval: 8000; running: true; onTriggered: { console.error("HANDOFF FAIL: timed out"); Qt.quit(); } }
}
''')
            environment = {**os.environ, 'QT_QPA_PLATFORM': 'offscreen', 'QML2_IMPORT_PATH': str(REPOSITORY / 'shell'),
                'QML_XHR_ALLOW_FILE_READ': '1', 'XDG_CONFIG_HOME': str(root / 'config'),
                'XDG_STATE_HOME': str(root / 'state'), 'XDG_DATA_HOME': str(root / 'data'),
                'BLOX_DATA_DIR': str(REPOSITORY / 'themes'), 'BLOX_USER_DATA_DIR': str(root / 'data/blox-user'),
                'BLOX_HYPRLAND_PREVIEW_STATE': str(preview_journal), 'BLOX_FAKE_COMPOSITOR': str(compositor),
                'BLOX_FAIL_RESTORE': '1' if fail_restore else '0', 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH']}
            if retained_preview:
                # Seed the durable journal in a separate helper process. The new
                # QML owner has no in-memory transaction when Apply asks to restore.
                subprocess.run(['python3', str(REPOSITORY / 'shell/scripts/theme/hyprland_preview.py'),
                    'apply', source], env=environment, capture_output=True, text=True, check=True)
                qml.write_text(qml.read_text().replace('preview.preview(' + source + '); drain.start();',
                    'drain.start();'))
                self.assertTrue(preview_journal.exists())
            result = subprocess.run(['quickshell', '-p', str(qml)], env=environment,
                capture_output=True, text=True, timeout=12)
            log = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, log)
            state = json.loads(compositor.read_text())
            if fail_restore:
                self.assertIn('HANDOFF RESTORE REFUSED', log)
                self.assertFalse(state['committed'])
                self.assertTrue(preview_journal.exists())
                self.assertEqual(len(state['batches']), 1)
            else:
                self.assertIn('HANDOFF PASS', log)
                self.assertFalse(preview_journal.exists())
                self.assertEqual(len(state['batches']), 2)
                self.assertEqual(state['batches'][1], options)
                self.assertTrue(state['committed'])
                self.assertEqual(set(state['options'].values()), {'42'})

    def test_pending_preview_is_restored_before_commit_and_close_cannot_undo_commit(self):
        self.run_handoff()

    def test_cold_owner_restores_retained_preview_before_commit(self):
        self.run_handoff(retained_preview=True)

    def test_restore_failure_keeps_journal_and_never_commits(self):
        self.run_handoff(fail_restore=True)


if __name__ == '__main__':
    unittest.main()
