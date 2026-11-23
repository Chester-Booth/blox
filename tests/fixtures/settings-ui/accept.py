#!/usr/bin/env python3
"""Capture the approved pages with identical saved data and explicit Qt scales."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from seed import dataset

repo = Path(__file__).resolve().parents[3]
reference = Path(os.environ.get('BLOX_REFERENCE_DIR', repo.parent / 'plans/blox-phase-4/unified-settings-and-themes/qml-mocks/reference-split'))
out = Path(os.environ.get('BLOX_TEST_EVIDENCE', '/tmp/blox-unblock-ui'))
out.mkdir(parents=True, exist_ok=True)
data = dataset(reference)
source = out / 'dataset.json'; source.write_text(json.dumps(data, indent=2)+'\n')
layouts = [('normal',1320,860,'1'),('narrow',980,660,'1'),('scale125',1320,860,'1.25'),('scale150',1320,860,'1.5'),('scale200',1320,860,'2')]
rows = []
for route_spec in os.environ.get('BLOX_ACCEPT_ROUTES','theme,bar,bar-items,colours,windows,widgets,targets,review').split(','):
    route, _, page = route_spec.partition('.')
    page = page or 'landing'
    for layout,w,h,scale in layouts:
        if layout not in os.environ.get('BLOX_ACCEPT_LAYOUTS','normal,narrow,scale125,scale150,scale200').split(','): continue
        for kind in os.environ.get('BLOX_ACCEPT_KINDS','production,reference').split(','):
            name = f"{kind}-{route_spec.replace('.', '-')}-{layout}"
            env = {**os.environ, 'QT_QPA_PLATFORM':'offscreen', 'QT_SCALE_FACTOR':scale, 'QML_XHR_ALLOW_FILE_READ':'1',
                'BLOX_TEST_SEEDED':'1', 'BLOX_TEST_DATASET':str(source), 'BLOX_TEST_REFERENCE':'1', 'BLOX_TEST_FLOW':'ready',
                'BLOX_TEST_ROUTE':route, 'BLOX_TEST_PAGE':page, 'BLOX_TEST_CAPTURE':str(out/(name+'.png')), 'BLOX_TEST_WIDTH':str(w), 'BLOX_TEST_HEIGHT':str(h),
                'BLOX_QML_MOCK_ROUTE':route, 'BLOX_QML_MOCK_PAGE':page, 'BLOX_QML_MOCK_FLOW':'ready', 'BLOX_QML_MOCK_CAPTURE':str(out/(name+'.png'))}
            if kind == 'production':
                command = [str(repo/'tests/fixtures/settings-ui/run.sh')]
                if route == 'review': env['BLOX_TEST_KEYBOARD'] = 'main'
                result = subprocess.run(command, env=env, capture_output=True, timeout=20)
            else:
                with tempfile.TemporaryDirectory(prefix='blox-reference-accept-') as temporary:
                    host = Path(temporary)
                    literal = json.dumps(data['mock'])
                    (host/'shell.qml').write_text(f'''import QtQuick
import "file://{reference}" as Reference
Reference.SettingsMock {{ width: {w}; height: {h}
    Component.onCompleted: {{ const data = {literal}; Object.keys(data).forEach(key => mockState[key] = data[key]); }}
}}
''')
                    env.update(XDG_STATE_HOME=str(reference/'fixtures/state'), BLOX_DATA_DIR=str(reference/'fixtures'), QML2_IMPORT_PATH=str(reference))
                    result = subprocess.run(['quickshell','-p',str(host/'shell.qml')], env=env, capture_output=True, timeout=20)
            log = result.stdout + result.stderr
            (out/(name+'.log')).write_bytes(log)
            ok = result.returncode == 0 and (out/(name+'.png')).exists() and b'FAIL:' not in log
            rows.append({'name':name, 'result':'pass' if ok else 'fail', 'scale':scale, 'fixture':'dataset.json'})
            print(name, rows[-1]['result'], flush=True)
(out/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
raise SystemExit(0 if all(row['result']=='pass' for row in rows) else 1)
