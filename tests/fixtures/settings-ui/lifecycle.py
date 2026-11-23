#!/usr/bin/env python3
"""Check real Settings draft/preview/discard/commit behaviour in isolated XDG roots."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from seed import dataset

repo = Path(__file__).resolve().parents[3]
reference = repo.parent / 'plans/blox-phase-4/unified-settings-and-themes/qml-mocks/reference-split'
out = Path(os.environ.get('BLOX_TEST_EVIDENCE', '/tmp/blox-settings-lifecycle'))
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='blox-settings-lifecycle-data-') as temporary:
    fixture = Path(temporary) / 'dataset.json'
    fixture.write_text(json.dumps(dataset(reference)))
    env = {**os.environ, 'QT_QPA_PLATFORM': 'offscreen', 'BLOX_TEST_SEEDED': '1',
           'BLOX_TEST_DRAG_CAPTURE': str(out / 'floating-drag.png'),
           'BLOX_TEST_DATASET': str(fixture), 'BLOX_TEST_SHELL': str(Path(__file__).with_suffix('.qml'))}
    result = subprocess.run([str(Path(__file__).with_name('run.sh'))], env=env,
                            capture_output=True, timeout=25)
    log = result.stdout + result.stderr
    (out / 'lifecycle.log').write_bytes(log)
    passed = result.returncode == 0 and b'LIFECYCLE PASS:' in log and b'LIFECYCLE FAIL:' not in log
    summary = {'result': 'pass' if passed else 'fail', 'checks': [
        'real control handlers update live bar and OSD/notification values',
        'bar drag updates live item region/order with floating proxy',
        'drafts and discarded edits preserve saved Settings bytes/revision',
        'close requires confirmation and discard restores original live Theme',
        'Apply preparation commits changed sections in one revision']}
    (out / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(log.decode())
    raise SystemExit(0 if passed else 1)
