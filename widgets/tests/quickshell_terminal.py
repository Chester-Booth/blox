"""Real Quickshell Process/NativeProvider import and lifecycle check, offscreen only."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--import-path', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
config = args.output / 'config'
config.mkdir()
qml = config / 'widgets/qml'
shutil.copytree(ROOT / 'widgets/qml', qml)
for name in ('libbloxwidgetsterminalplugin.so', '.build.json'):
    shutil.copyfile(args.import_path / 'Blox/Widgets/Terminal' / name, qml / 'Blox/Widgets/Terminal' / name)
# AF_UNIX paths must fit sun_path; long evidence directory names do not.
runtime = tempfile.TemporaryDirectory(prefix='bnt-', dir=Path.home() / '.cache')
broker = config / 'fixture_broker.py'
broker.write_text('''import json,sys
sys.path.insert(0, LIBRARY)
from blox_widgets.broker import OutputQueue
consumers={}
old=None
output=OutputQueue()
def emit(message):
 if 'snapshot' in message:message['_terminal']=True
 output.emit(message)
 while output:
  data=output.chunk();sys.stdout.buffer.write(data);sys.stdout.buffer.flush();output.advance(len(data))
def snapshot(id,gen,revision,columns=12,rows=2):
 cells=["界","","e\\u0301"," ","█"]+[" "]*(columns-5)
 retained=[dict(runs=[dict(column=0,cells=cells,foreground="#d5def9")])]
 for r in range(1,rows): retained.append(dict(runs=[dict(column=0,cells=[" "]*columns,background="#cc241d")]))
 return dict(_terminal=True,consumerId=id,snapshot=dict(generation=gen,revision=revision,observedMonotonicMs=revision,state="ready",error="",value=dict(generation=gen,attempt=1,sequence=revision,columns=columns,rowCount=rows,rows=retained,changedRuns=[],readiness="partial",lifecycle="running",restartPending=False,bytesObserved=revision)))
for line in sys.stdin:
 request=json.loads(line); op=request["op"]; id=request.get("consumerId")
 if op=="shutdown":break
 if op=="subscribe":
  if old:emit(old)
  gen=request["generation"];consumers[id]=[gen,3]
  emit(dict(consumerId=id,snapshot=dict(generation=gen,revision=0,observedMonotonicMs=0,state="preparing",value={},error="")))
  old=snapshot(id,gen,1);emit(old)
  queue=OutputQueue()
  queue.emit(snapshot(id,gen,2));queue.emit(snapshot(id,gen,3))
  assert len(queue.snapshots)==1
  while queue:
   data=queue.chunk();sys.stdout.buffer.write(data);sys.stdout.buffer.flush();queue.advance(len(data))
 elif op=="unsubscribe": consumers.pop(id,None)
 elif op=="action":
  gen,rev=consumers[id]; consumers[id][1]+=1
  emit(dict(requestId=request["requestId"],op="action",consumerId=id,generation=gen,ok=True,result=dict(code="accepted")))
  if request["action"]=="resize":emit(snapshot(id,gen,rev+1,request["payload"]["columns"],request["payload"]["rows"]))
 emit(dict(requestId=request["requestId"],ok=True))
'''.replace('LIBRARY', json.dumps(str(ROOT / 'widgets/lib'))))
source = '''import QtQuick
import QtQuick.Window
import Quickshell
import "widgets/qml/Blox/Widgets/Providers" as Providers
import "widgets/qml/Blox/Widgets/Native" as Native
ShellRoot {
    id: root
    property var envelope: ({})
    property int stage: 0
    property int actions: 0
    property int failures: 0
    property var retained: ({})
    function check(ok, text) { if (!ok) { root.failures++; console.error("NATIVE_TERMINAL_FAILURE " + text); } }
    Providers.NativeProvider {
        id: provider
        enabled: true
        brokerCommand: COMMAND
        onSnapshotReady: (id, value) => {
            if (id === "fixture") root.envelope = value;
        }
        onActionResult: (id, generation, result) => { if (result.code === "accepted") root.actions++; }
        onConnectionError: message => { root.failures++; console.error("NATIVE_TERMINAL_FAILURE " + message); }
    }
    Window {
        visible: true; width: 420; height: 160
        Native.TerminalView {
            id: terminal
            anchors.fill: parent
            snapshot: root.envelope
            context: ({fullscreenMode:"fit",scrollbars:"hide"})
            settings: ({columns:12,rows:2})
        }
    }
    Timer {
        interval: 100; repeat: true; running: true
        property int attempts: 0
        onTriggered: {
            attempts++;
            if (attempts>80) { root.check(false,"deadline"); console.log("NATIVE_TERMINAL_RESULT " + JSON.stringify({failures:root.failures,stage:root.stage})); Qt.quit(); return; }
            if (root.stage===0 && terminal.contentReady) {
                root.check(root.envelope.value.nonblankCells===3,"native count");
                root.check(root.envelope.revision===3,"OutputQueue coalesced frame arrived");
                root.check(root.envelope.value.rows===undefined,"no QML cells");
                root.retained=root.envelope;
                provider.unsubscribe("fixture");
                root.check(!terminal.contentReady,"unsubscribe invalidates model immediately");
                root.stage=1;
            } else if (root.stage===1) {
                root.envelope=root.retained;
                root.check(!terminal.contentReady,"expired token remains invalid");
                provider.subscribe("fixture","terminal",{columns:12,rows:2},2);
                root.stage=2;
            } else if (root.stage===2 && terminal.contentReady) {
                root.check(root.envelope.generation===2,"stale generation was rejected");
                provider.dispatchAction("fixture","resize",{columns:20,rows:3},2);
                root.stage=3;
            } else if (root.stage===3 && root.actions===1 && root.envelope.value.columns===20 && terminal.contentReady) {
                root.check(root.envelope.value.rowCount===3,"resize observation");
                provider.unsubscribe("fixture");
                console.log("NATIVE_TERMINAL_RESULT "+JSON.stringify({failures:root.failures,stage:root.stage,actions:root.actions,configRoot:true,offscreen:true}));
                running=false;
                Qt.quit();
            }
        }
    }
    Component.onCompleted: provider.subscribe("fixture","terminal",{columns:12,rows:2},1)
}'''.replace('COMMAND', json.dumps([sys.executable, '-B', str(broker)]))
(config / 'shell.qml').write_text(source)
env = dict(os.environ)
env.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='generic',
    QT_QUICK_CONTROLS_STYLE='Basic', QML_DISABLE_DISK_CACHE='1', HOME=str(args.output),
    XDG_CONFIG_HOME=str(args.output), XDG_CACHE_HOME=str(args.output), XDG_DATA_HOME=str(args.output),
    XDG_RUNTIME_DIR=runtime.name, QML_IMPORT_PATH=str(qml),
    DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(args.output / 'no-bus'),
    DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(args.output / 'no-system-bus'))
for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'QML2_IMPORT_PATH', 'QT_PLUGIN_PATH', 'QS_CONFIG_PATH', 'QS_CONFIG_NAME'):
    env.pop(name, None)
try:
    completed = subprocess.run(['quickshell','--no-duplicate','--no-color','--path',str(config)],
        env=env, capture_output=True, text=True, timeout=15)
except subprocess.TimeoutExpired as error:
    log = (error.stdout or b'').decode() + (error.stderr or b'').decode()
    (args.output / 'quickshell.log').write_text(log)
    raise RuntimeError(log) from error
finally:
    runtime.cleanup()
log = completed.stdout + completed.stderr
(args.output / 'quickshell.log').write_text(log)
markers = [line.split('NATIVE_TERMINAL_RESULT ',1)[1] for line in log.splitlines() if 'NATIVE_TERMINAL_RESULT ' in line]
assert completed.returncode == 0 and len(markers) == 1, log
result = json.loads(markers[0])
(args.output / 'result.json').write_text(json.dumps(result,indent=2)+'\n')
assert result.get('failures') == 0 and result.get('stage') == 3, log
assert not any(text in log for text in ('QQmlExpression:', 'is unavailable', 'is not installed', 'Cannot assign', 'Unable to assign')), log
print(json.dumps(result,indent=2))
