#!/usr/bin/env python3
"""Exercise the actual Quickshell Process exit ordering with inert Settings helpers."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import resource
import shutil
import subprocess
import sys
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--runtime-parent', required=True, type=Path)
    args = parser.parse_args()
    assert sys.dont_write_bytecode, 'Use python3 -B'
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    nice_before = os.getpriority(os.PRIO_PROCESS, 0)
    assert nice_before in (0, 15)
    if nice_before == 0:
        os.nice(15)
    source = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    output.mkdir(mode=0o700)
    executable = shutil.which('quickshell')
    assert executable, 'Native Quickshell is required'
    runtime_parent = args.runtime_parent.resolve()
    assert runtime_parent.is_dir() and runtime_parent.stat().st_uid == os.getuid()
    rows = []
    for case in ('cold', 'disabled', 'hyprland-failure', 'apply-failure'):
        root = output / case
        root.mkdir(mode=0o700)
        qml = root / 'qml'
        qml.mkdir()
        scripts = qml / 'scripts'
        scripts.mkdir()
        for name in ('SettingsController.qml', 'SettingsState.qml'):
            shutil.copy2(source / 'shell/services' / name, qml / name)
        payload = {'version': 1, 'ok': True, 'code': 'ok', 'message': '', 'data': {
            'schemaVersion': 1, 'revision': 0, 'beforeRevision': 0, 'afterRevision': 0,
            'observedAt': 1, 'dirty': False, 'conflict': False, 'changedComponents': [],
            'commitState': 'not-applicable', 'rollbackState': 'not-attempted',
            'error': None, 'settings': {}}}
        for name, operation, expected_args in (
                ('hyprland_settings.py', 'hyprland-recover', ['recover']),
                ('apply_runtime.py', 'apply-recover', ['recover']),
                ('settings_runtime.py', 'get', ['get', '{}'])):
            failing = case == 'hyprland-failure' and operation == 'hyprland-recover' or case == 'apply-failure' and operation == 'apply-recover'
            text = 'from pathlib import Path\nimport json, os, sys\n'
            text += 'assert sys.argv[1:] == ' + repr(expected_args) + '\n'
            text += 'with (Path(__file__).resolve().parents[1] / "events.jsonl").open("a") as stream:\n'
            text += '    stream.write(json.dumps({"helper": ' + repr(operation) + ', "pid": os.getpid()}) + "\\n")\n'
            if failing:
                text += 'raise SystemExit(1)\n'
            elif operation == 'get':
                text += 'print(json.dumps(' + repr(payload) + '))\n'
            (scripts / name).write_text(text)
        (qml / 'shell.qml').write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
    property bool sawRecovery: false
    property bool reported: false
    SettingsController { id: owner; enableColdRecovery: ''' + ('false' if case == 'disabled' else 'true') + ''' }
    Connections { target: owner; function onRecoveringChanged() { if (owner.recovering) sawRecovery = true; } }
    function finish() {
        if (reported) return;
        reported = true;
        console.log("SETTINGS_COLD_RESULT " + JSON.stringify({busy: owner.busy,
            recovering: owner.recovering, settingsPresent: owner.settings !== null,
            error: owner.error, requestSerial: owner.requestSerial,
            completed: owner.completedResult !== null}));
        Qt.quit();
    }
    Timer { running: true; repeat: true; interval: 20; onTriggered: {
        if (owner.completedResult !== null || (sawRecovery && !owner.recovering && !owner.busy && ''' + ('false' if case == 'cold' else 'true') + ''')) finish();
    } }
    Timer { running: true; interval: ''' + ('150' if case == 'disabled' else '3000') + '''; onTriggered: finish() }
}
''')
        runtime = runtime_parent / ('bsc-' + uuid.uuid4().hex[:10])
        runtime.mkdir(mode=0o700)
        assert len(os.fsencode(str(runtime / 'quickshell/by-id/xxxxxxxxxxx/ipc.sock'))) < 108
        for role in ('home', 'config', 'cache', 'state', 'data', 'tmp'):
            (root / role).mkdir(mode=0o700)
        env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C.UTF-8', 'HOME': str(root / 'home'),
               'XDG_RUNTIME_DIR': str(runtime), 'XDG_CONFIG_HOME': str(root / 'config'),
               'XDG_CACHE_HOME': str(root / 'cache'), 'XDG_STATE_HOME': str(root / 'state'),
               'XDG_DATA_HOME': str(root / 'data'), 'TMPDIR': str(root / 'tmp'),
               'QT_QPA_PLATFORM': 'offscreen', 'QT_QUICK_BACKEND': 'software',
               'QML_DISABLE_DISK_CACHE': '1', 'QS_DISABLE_CRASH_HANDLER': '1',
               'PYTHONDONTWRITEBYTECODE': '1'}
        argv = [executable, '--no-duplicate', '--path', str(qml)]
        begin = time.monotonic_ns()
        timed_out = False
        try:
            child = subprocess.run(argv, env=env, capture_output=True, timeout=5)
        except subprocess.TimeoutExpired as error:
            timed_out = True
            child = subprocess.CompletedProcess(argv, None, error.stdout or b'', error.stderr or b'')
        end = time.monotonic_ns()
        (root / 'stdout.log').write_bytes(child.stdout)
        (root / 'stderr.log').write_bytes(child.stderr)
        matches = [line.split('SETTINGS_COLD_RESULT ', 1)[1] for line in child.stdout.decode().splitlines() if 'SETTINGS_COLD_RESULT ' in line]
        observed = json.loads(matches[0]) if len(matches) == 1 else None
        events = [json.loads(line) for line in (qml / 'events.jsonl').read_text().splitlines()] if (qml / 'events.jsonl').exists() else []
        expected = [] if case == 'disabled' else ['hyprland-recover']
        if case in ('cold', 'apply-failure'):
            expected.append('apply-recover')
        if case == 'cold':
            expected.append('get')
        okay = child.returncode == 0 and not child.stderr and observed is not None
        okay = okay and [e['helper'] for e in events] == expected
        okay = okay and observed == {'busy': False, 'recovering': False,
            'settingsPresent': case == 'cold', 'error': None,
            'requestSerial': 1 if case == 'cold' else 0, 'completed': case == 'cold'}
        record = {'case': case, 'passed': okay, 'argv': argv, 'environment': env,
                  'beginNs': begin, 'endNs': end, 'exit': child.returncode, 'waited': True,
                  'timeout': timed_out, 'launcherNiceBefore': nice_before,
                  'observed': observed, 'helperEvents': events,
                  'runtimeRetained': str(runtime), 'mainNice': os.getpriority(os.PRIO_PROCESS, 0),
                  'sourceSha256': hashlib.sha256((qml / 'SettingsController.qml').read_bytes()).hexdigest()}
        (root / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        rows.append(record)
    (output / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps({'cases': len(rows), 'passed': sum(r['passed'] for r in rows),
                      'nativeManagerOperations': 0, 'performanceAccepted': False}))
    return 0 if all(r['passed'] for r in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
