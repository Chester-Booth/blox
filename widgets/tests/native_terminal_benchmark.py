"""Bounded full-keyframe component benchmark, not production transport acceptance.

Paint counters are not presentation proof. The native case deliberately sends
full keyframes rather than the broker's coalesced row patches.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--import-path', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--variant', choices=['native', 'canvas'], required=True)
parser.add_argument('--seconds', type=int, default=16)
parser.add_argument('--unicode-first', action='store_true')
parser.add_argument('--reference-canvas', type=Path, default=Path(__file__).parent / 'fixtures/TerminalCanvasReference.qml')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
(args.output / 'runtime').mkdir(mode=0o700)
os.environ.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='generic',
    QML_DISABLE_DISK_CACHE='1', QT_SCALE_FACTOR='1', QT_SCREEN_SCALE_FACTORS='', HOME=str(args.output),
    XDG_CONFIG_HOME=str(args.output), XDG_CACHE_HOME=str(args.output), XDG_DATA_HOME=str(args.output),
    XDG_RUNTIME_DIR=str(args.output / 'runtime'),
    DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(args.output / 'no-bus'),
    DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(args.output / 'no-system-bus'))
for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'QML_IMPORT_PATH', 'QML2_IMPORT_PATH', 'QT_PLUGIN_PATH'):
    os.environ.pop(name, None)
from PySide6.QtCore import QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQuick import QQuickView

reference = args.reference_canvas.read_text()
if 'property int paints:' not in reference:
    reference = reference.replace('    id: root', '    id: root\n    property int paints: 0\n    onPainted: paints++', 1)
(args.output / 'ReferenceCanvas.qml').write_text(reference)
component = '''import QtQuick
import Blox.Widgets.Terminal 1.0
TerminalSurface {}''' if args.variant == 'native' else 'import QtQuick\nReferenceCanvas {}'
(args.output / 'CellGrid.qml').write_text(component)
qml = '''import QtQuick
import Blox.Widgets.Terminal 1.0
Rectangle {
    id: root
    width: 1700; height: 800; color: "#112233"
    property int ticks: 0
    property real started: 0
    property real lastTick: 0
    property var tickGaps: []
    property var templates: []
    property var protocolErrors: []
    property real publishMs: 0
    property real heartbeatLast: 0
    property var heartbeatGaps: []
    signal finished(string result)
    TerminalDecoder {
        id: decoder
        onMessageReady: message => grids.itemAt(Number(message.consumerId.slice(8))).frame = message.snapshot.value
        onProtocolError: error => { root.protocolErrors.push(error); console.error(error); }
    }
    Repeater {
        id: grids
        model: 6
        delegate: CellGrid {
            required property int index
            x: (index % 3)*560; y: Math.floor(index/3)*360
            fontFamily: "monospace"; fontSize: 12; cellWidth: 8; cellHeight: 13; ascent: 10
        }
    }
    function makeFrame(n, phase) {
        const rows = [], changed = [];
        for (let r = 0; r < 21; ++r) {
            const cells = [];
            for (let c = 0; c < 62; ++c) {
                const sparse = n === 1 || n === 3;
                cells.push(n === 0 ? (r > 9 + c % 7 ? (phase ? "▓" : "█") : " ") :
                    sparse && c % 9 ? " " : String.fromCharCode(65 + (r+c+phase)%26));
            }
            const run = {column: 0, cells: cells, foreground: "#d5def9", background: null};
            rows.push({runs:[run]}); changed.push(Object.assign({row:r},run));
        }
        if (UNICODE_FIRST) { rows[0].runs[0].cells[0]="界"; rows[0].runs[0].cells[1]=""; rows[0].runs[0].cells[2]="e\\u0301"; }
        return {generation: 1, attempt: 1, sequence: 123456789, columns: 62, rowCount: 21, rows:rows,
            changedRuns:changed, readiness:"partial", lifecycle:"running"};
    }
    Component.onCompleted: {
        for (let i = 0; i < 6; ++i) {
            decoder.subscribe("fixture-"+i,"terminal",1);
            const phases = [];
            for (let phase=0; phase<2; ++phase) {
                const frame=root.makeFrame(i,phase);
                if (VARIANT === "native") { frame.rowFormat="full-v1"; delete frame.changedRuns; }
                phases.push(JSON.stringify({consumerId:"fixture-"+i,
                    snapshot:{generation:1, revision:123456789, observedMonotonicMs:0,state:"ready",error:"",value:frame}}));
            }
            templates.push(phases);
        }
    }
    Timer {
        interval: 1; running: true; repeat: true
        onTriggered: {
            const now=Date.now();
            if (root.heartbeatLast) root.heartbeatGaps.push(now-root.heartbeatLast);
            root.heartbeatLast=now;
        }
    }
    Timer {
        interval:16; repeat:true; running:true
        onTriggered: {
            const now=Date.now();
            if (!root.started) root.started=now;
            if (root.lastTick && now-root.started>1000) root.tickGaps.push(now-root.lastTick);
            root.lastTick=now; root.ticks++;
            const begin=Date.now();
            for (let i=0; i<6; ++i) {
                const line=root.templates[i][root.ticks%2].replace(/123456789/g,String(root.ticks));
                if (VARIANT === "native") decoder.readChunk(line+"\\n");
                else grids.itemAt(i).frame=JSON.parse(line).snapshot.value;
            }
            root.publishMs+=Date.now()-begin;
            if (now-root.started>=SECONDS*1000) {
                running=false;
                const result={ticks:root.ticks,elapsedMs:Date.now()-root.started,publishMs:root.publishMs,
                    tickGapsMs:root.tickGaps,heartbeatGapsMs:root.heartbeatGaps,protocolErrors:root.protocolErrors,grids:[]};
                for (let i=0; i<6; ++i) result.grids.push(VARIANT === "native" ? grids.itemAt(i).diagnostics : {completedFrames:grids.itemAt(i).paints});
                root.finished(JSON.stringify(result));
            }
        }
    }
}'''.replace('VARIANT', json.dumps(args.variant)).replace('SECONDS', str(args.seconds)).replace('UNICODE_FIRST', str(args.unicode_first).lower())
(args.output / 'fixture.qml').write_text(qml)
app = QGuiApplication([])
view = QQuickView()
view.engine().addImportPath(str(args.import_path))
view.setSource(QUrl.fromLocalFile(str(args.output / 'fixture.qml')))
assert view.status() != QQuickView.Status.Error, view.errors()
wall = time.perf_counter()
main_cpu = time.thread_time()
cpu = time.process_time()
swaps = [0]
view.frameSwapped.connect(lambda: swaps.__setitem__(0, swaps[0]+1))
def finish(raw):
    result=json.loads(raw)
    result.update(variant=args.variant,wallSeconds=time.perf_counter()-wall,
        processCpuSeconds=time.process_time()-cpu,mainCpuSeconds=time.thread_time()-main_cpu,
        maxRssKiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,offscreen=True,backend='software',swaps=swaps[0],
        sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'widgets/native/terminal.h',ROOT/'widgets/native/terminal.cpp')})
    def own_rss():
        return int(Path('/proc/self/statm').read_text().split()[1]) * os.sysconf('SC_PAGE_SIZE') // 1024
    result['rssBeforeGcKiB'] = own_rss()
    view.engine().collectGarbage()
    result['rssAfterGcKiB'] = own_rss()
    (args.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    summary=dict(result); summary.pop('tickGapsMs'); summary.pop('heartbeatGapsMs')
    gaps = sorted(result['heartbeatGapsMs'])
    summary['heartbeatGapMs'] = {'p99':gaps[len(gaps)*99//100], 'max':max(gaps)}
    print(json.dumps(summary,indent=2),flush=True)
    failed = bool(result['protocolErrors']) or any(grid.get('completedFrames', 0) <= 0 for grid in result['grids'])
    app.exit(1 if failed else 0)
view.rootObject().finished.connect(finish)
view.show();exit_code=app.exec();view.close();sys.exit(exit_code)
