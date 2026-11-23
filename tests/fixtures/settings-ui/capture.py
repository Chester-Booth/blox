#!/usr/bin/env python3
"""Capture production and approved fixture views at normal, narrow and scaled sizes."""
import json, os, subprocess, tempfile
from seed import dataset
from pathlib import Path
repository = Path(__file__).resolve().parents[3]
ref = Path(os.environ.get('BLOX_REFERENCE_DIR', repository.parent / 'plans/blox-phase-4/unified-settings-and-themes/qml-mocks/reference-split'))
out = Path(os.environ.get('BLOX_TEST_EVIDENCE', '/tmp/blox-settings-evidence'))
out.mkdir(parents=True, exist_ok=True)
data=dataset(ref)
source=out/"dataset.json"; source.write_text(json.dumps(data,indent=2)+"\n")
flows={'ready':'ready','success':'success-mixed','drift':'drift-detected','partial':'failure-target-retained','retrying':'retrying','rolled-back':'rolled-back','import-sections':'ready','import-sensitive':'ready','export':'ready'}
for name,flow in flows.items():
 for layout,w,h,scale in [('normal',1320,860,'1'),('narrow',980,660,'1'),('scaled',1320,860,'1.5')]:
  env={**os.environ,'QT_QPA_PLATFORM':'offscreen','QT_SCALE_FACTOR':scale,'QML_XHR_ALLOW_FILE_READ':'1','BLOX_TEST_SEEDED':'1','BLOX_TEST_DATASET':str(source),'BLOX_TEST_REFERENCE':'1','BLOX_TEST_FLOW':name,'BLOX_TEST_WIDTH':str(w),'BLOX_TEST_HEIGHT':str(h),'BLOX_QML_MOCK_FLOW':flow}
  if name.startswith('import'):
   env.update(BLOX_QML_MOCK_DIALOG='import-review',BLOX_QML_MOCK_BUNDLE_STEP='sensitive' if name=='import-sensitive' else 'sections',BLOX_QML_MOCK_POPUP='1')
  if name=='export': env.update(BLOX_QML_MOCK_DIALOG='export-review',BLOX_QML_MOCK_BUNDLE_STEP='contents',BLOX_QML_MOCK_POPUP='1')
  for kind in ['production','reference']:
   env['BLOX_TEST_CAPTURE']=str(out/f'{kind}-{name}-{layout}.png')
   env['BLOX_QML_MOCK_CAPTURE' if name not in ('import-sections','import-sensitive','export') else 'BLOX_QML_MOCK_BUNDLE_CAPTURE']=env['BLOX_TEST_CAPTURE']
   if kind=='production': command=[str(repository / 'tests/fixtures/settings-ui/run.sh')]
   else:
    host=Path(tempfile.mkdtemp(prefix='blox-ref-'))
    (host/'shell.qml').write_text(f'import QtQuick\nimport "file://{ref}" as Reference\nReference.SettingsMock {{ width: {w}; height: {h}; Component.onCompleted: {{ const data = {json.dumps(data["mock"])}; Object.keys(data).forEach(key => mockState[key] = data[key]); }} }}\n')
    command=['quickshell','-p',str(host/'shell.qml')]
    env.update(XDG_STATE_HOME=str(ref/'fixtures/state'),BLOX_DATA_DIR=str(ref/'fixtures'),QML2_IMPORT_PATH=str(ref))
   p=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=12)
   (out/f'{kind}-{name}-{layout}.log').write_bytes(p.stdout)
   print(kind,name,layout,p.returncode,flush=True)
