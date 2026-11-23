"""Trusted run context through the real adapters and owned offscreen transport."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture

from blox_widgets.model import default_widget

ROOT = Path(__file__).resolve().parents[2]


class ApplicationTransportTests(unittest.TestCase):
    def setUp(self):
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)

    def test_host_native_adapter_broker_and_finite_environment(self):
        self.assertIsNotNone(shutil.which('quickshell'), 'Owned transport requires Quickshell')
        with tempfile.TemporaryDirectory(prefix='blox-trusted-transport-') as temporary:
            root = Path(temporary)
            producer = ('import os; from pathlib import Path; p=Path("count"); '
                        'n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); '
                        'print(os.environ.get("BLOX_WIDGET_ACTION_CONTEXT","absent")+":"+str(n))')
            finite = ('import os; from pathlib import Path; '
                      'p=Path("context"); p.open("a").write(os.environ["BLOX_WIDGET_ACTION_CONTEXT"]+"\\n")')
            widget = default_widget('command','fixture', {'command':[sys.executable,'-c',producer],
                'workingDirectory':str(root), 'actions':{'left':{'kind':'run','command':[sys.executable,'-c',finite],
                'workingDirectory':str(root),'environment':{},'timeoutSeconds':3},'right':None}})
            source = '''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    property int stage: 0
    property int unavailableCount: 0
    NativeProvider {
        id: provider; enabled: true; brokerCommand: __COMMAND_JSON__
        brokerEnvironment: ({PYTHONPATH:__LIBRARY_JSON__, BLOX_WIDGET_ACTION_CONTEXT:"inherited-forged"})
        onSnapshotReady: (id, snapshot) => {
            if (snapshot.state !== "ready") return;
            if (snapshot.value.text === "absent:2" && stage === 1 && unavailableCount === 1) {
                stage=2; host.visible=false; Qt.exit(0);
            }
        }
        onActionResult: (id, generation, result) => {
            if (result.code === "unavailable") {
                unavailableCount++;
                host.view.actionRequested("activate",{button:"left"});
            } else if (result.code !== "accepted") Qt.exit(8);
        }
    }
    Widgets.WidgetHost {
        id: host; widget: __WIDGET_JSON__; provider: provider
        placementBounds: Qt.rect(0,0,800,600)
        workspace: ({id:4,name:"4",special:false,empty:true})
        trustedLaunchContext: ({outputName:"DP-2",workspace:{id:4,name:"4",special:false}})
        onActionRequested: trustedLaunchContext.outputName="observer-changed"
        onPhaseChanged: {
            if (phase === "visible" && stage === 0) {
                stage=1;
                provider.dispatchAction(host.consumerId,"activate",{button:"left"},host.revealGeneration,
                    {outputName:"DP-2",workspace:{id:4,name:"named",special:false}});
            }
        }
    }
    Timer { interval:4000; running:true; onTriggered:Qt.exit(9) }
}'''.replace('__COMMAND_JSON__',json.dumps([sys.executable,'-m','blox_widgets.broker'])).replace(
                '__LIBRARY_JSON__',json.dumps(self.supervision.pythonpath(str(ROOT/'widgets/lib')))).replace('__WIDGET_JSON__',json.dumps(widget))
            fixture=root/'fixture.qml'; fixture.write_text(source)
            environment=dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
                QT_QPA_PLATFORMTHEME='generic', QT_STYLE_OVERRIDE='Fusion',
                DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent',DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent',
                HOME=str(root),XDG_CONFIG_HOME=str(root),XDG_DATA_HOME=str(root),XDG_CACHE_HOME=str(root),
                XDG_RUNTIME_DIR=str(root),QML_IMPORT_PATH=os.pathsep.join(filter(None,[os.environ.get('QML_IMPORT_PATH'),str(ROOT/'widgets/qml')])))
            for name in ('DISPLAY','WAYLAND_DISPLAY','HYPRLAND_INSTANCE_SIGNATURE'):
                environment.pop(name,None)
            result=subprocess.run(['quickshell','--no-color','--path',str(fixture)],env=environment,
                                  capture_output=True,text=True,timeout=7)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual((root/'count').read_text(),'2')
            self.assertEqual([json.loads(line) for line in (root/'context').read_text().splitlines()], [{'workspaceId':4}])


if __name__ == '__main__': unittest.main()
