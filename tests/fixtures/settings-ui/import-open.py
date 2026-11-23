#!/usr/bin/env python3
"""Check real imported-theme selection, source reload and draft preservation in isolated XDG roots."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from seed import dataset

repo = Path(__file__).resolve().parents[3]
reference = repo.parent / 'plans/blox-phase-4/unified-settings-and-themes/qml-mocks/reference-split'
out = Path(os.environ.get('BLOX_TEST_EVIDENCE', '/tmp/blox-settings-import-open'))
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='blox-settings-import-open-data-') as temporary:
    fixture = Path(temporary) / 'dataset.json'
    fixture.write_text(json.dumps(dataset(reference)))
    env = {**os.environ, 'QT_QPA_PLATFORM': 'offscreen', 'BLOX_TEST_SEEDED': '1',
           'BLOX_TEST_REPO': str(repo),
           'BLOX_TEST_DATASET': str(fixture), 'BLOX_TEST_SHELL': str(Path(__file__).with_suffix('.qml'))}
    result = subprocess.run([str(Path(__file__).with_name('run.sh'))], env=env,
                            capture_output=True, timeout=25)
    log = result.stdout + result.stderr
    (out / 'import-open.log').write_bytes(log)
    passed = result.returncode == 0 and b'IMPORT OPEN PASS:' in log and b'IMPORT OPEN FAIL:' not in log
    summary = {'result': 'pass' if passed else 'fail'}
    (out / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(log.decode())
    raise SystemExit(0 if passed else 1)
