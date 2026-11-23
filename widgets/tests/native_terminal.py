"""Focused private native terminal checks. No desktop, live providers or GPU.

Build the plugin into a cache first. Run with --import-path and a new --output
directory. --reference-canvas can name a frozen preimage for exact old-code
comparisons; the default is a test-only copy of its full-grid paint path.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import unittest
import shiboken6

ROOT = Path(__file__).resolve().parents[2]
PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument('--import-path', type=Path, required=True)
PARSER.add_argument('--output', type=Path, required=True)
PARSER.add_argument('--dpr', type=float, default=1)
PARSER.add_argument('--reference-canvas', type=Path, default=Path(__file__).parent / 'fixtures/TerminalCanvasReference.qml')
PARSER.add_argument('--case', action='append', help='Run only this focused test method; repeat for several methods.')
ARGS = PARSER.parse_args()
ARGS.output.mkdir(parents=True, exist_ok=False)
(ARGS.output / 'runtime').mkdir(mode=0o700)
os.environ.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='generic',
    QT_QUICK_CONTROLS_STYLE='Basic', QML_DISABLE_DISK_CACHE='1', QT_SCALE_FACTOR=str(ARGS.dpr),
    QT_SCREEN_SCALE_FACTORS='', HOME=str(ARGS.output), XDG_CONFIG_HOME=str(ARGS.output),
    XDG_CACHE_HOME=str(ARGS.output), XDG_DATA_HOME=str(ARGS.output), XDG_RUNTIME_DIR=str(ARGS.output / 'runtime'),
    DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(ARGS.output / 'no-session-bus'),
    DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(ARGS.output / 'no-system-bus'))
for _name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'QT_PLUGIN_PATH',
              'QT_QPA_PLATFORM_PLUGIN_PATH', 'QML_IMPORT_PATH', 'QML2_IMPORT_PATH'):
    os.environ.pop(_name, None)

from PySide6.QtCore import QObject, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQuick import QQuickView

sys.path.insert(0, str(ROOT / 'widgets/lib'))
from blox_widgets.terminal import AnsiScreen

APP = QGuiApplication([])
OBSERVATIONS = {}
(ARGS.output / 'ReferenceCanvas.qml').write_bytes(ARGS.reference_canvas.read_bytes())

QML = '''import QtQuick
import Blox.Widgets 1.0
import Blox.Widgets.Terminal 1.0
Rectangle {
    id: root
    width: 1000; height: 760; color: "#112233"
    property var envelope: ({})
    property var lastMessage: ({})
    property bool adopt: true
    property int messages: 0
    property int failures: 0
    property bool clearOnMessage: false
    property bool reference: false
    property var referenceFrame: ({})
    property real origin: 0
    property real cw: 8
    property real ch: 13
    property real scale: 1
    property string family: "monospace"
    property real pointSize: 12
    property var host: null
    property string hostId: ""
    property int hostGeneration: 0
    property string callbackSignal: ""
    property string callbackAction: ""
    property string callbackConsumer: "fixture"
    property var callbackFrame: ({})
    property string callbackWire: ""
    property int callbackHits: 0
    function reenter(signal) {
        if (callbackSignal !== signal || !callbackAction) return;
        const action = callbackAction;
        callbackAction = "";
        callbackHits++;
        if (action === "unsubscribe") decoder.unsubscribe(callbackConsumer);
        else if (action === "clear") decoder.clear();
        else if (action === "replace") surface.frame = callbackFrame;
        else if (action === "empty") surface.frame = ({});
        else if (action === "stage") decoder.readChunk(callbackWire);
    }
    property alias fixtureProvider: provider
    function subscribe(id, generation) { return decoder.subscribe(id, "terminal", generation); }
    function unsubscribe(id) { decoder.unsubscribe(id); }
    function feed(text) { decoder.readChunk(text); }
    function acceptLast() { root.envelope = root.lastMessage.snapshot; }
    function resetAdoption() {
        root.envelope = ({});
        surface.frame = Qt.binding(function() { return root.envelope.value || ({}); });
        root.adopt = true;
    }
    function makeHost() { root.host = hostComponent.createObject(root); }
    TerminalDecoder {
        id: decoder
        objectName: "decoder"
        onMessageReady: message => {
            root.messages++;
            root.lastMessage = message;
            if (root.clearOnMessage) { root.clearOnMessage=false; decoder.clear(); return; }
            if (message.snapshot) {
                if (root.adopt) root.envelope = message.snapshot;
                provider.snapshotReady(message.consumerId, message.snapshot);
            }
        }
        onProtocolError: root.failures++
    }
    QtObject {
        id: provider
        signal snapshotReady(string consumerId, var envelope)
        function subscribe(id, kind, options, generation) {
            root.hostId = id; root.hostGeneration = generation;
            decoder.subscribe(id, kind, generation);
        }
        function unsubscribe(id) { decoder.unsubscribe(id); }
    }
    Component {
        id: hostComponent
        WidgetHost {
            provider: root.fixtureProvider
            placementBounds: Qt.rect(0, 0, 1000, 760)
            widget: ({id: "native-fixture", kind: "terminal", enabled: true, visibility: "always",
                workspaces: {mode: "all", ids: [], ranges: []},
                placement: {anchor: "top-left", x: 0, y: 120, width: 600, height: 300, sizing: "fixed"},
                appearance: {backgroundOpacity: 1, scrollbars: "hide"},
                fullscreen: {enabled: true, mode: "fit"},
                settings: {columns: 8, rows: 4}})
        }
    }
    Connections {
        target: surface
        function onContentReadyChanged() { root.reenter(surface.contentReady ? "ready" : "notReady"); }
        function onGridChanged() { root.reenter("grid"); }
        function onGeometryUpdated() { root.reenter("geometry"); }
        function onWidthChanged() { root.reenter("width"); }
        function onHeightChanged() { root.reenter("height"); }
        function onFrameChanged() { root.reenter("frame"); }
        function onDiagnosticsChanged() { root.reenter("diagnostics"); }
        function onAppearanceChanged() { root.reenter("appearance"); }
    }
    TerminalSurface {
        id: surface
        objectName: "surface"
        x: root.origin; y: root.origin; visible: !root.reference
        frame: root.envelope.value || ({})
        fontFamily: root.family; fontSize: root.pointSize
        cellWidth: root.cw; cellHeight: root.ch; ascent: 10
        drawScale: root.scale
    }
    ReferenceCanvas {
        id: reference
        objectName: "reference"
        x: root.origin; y: root.origin; visible: root.reference
        frame: root.referenceFrame
        fontFamily: root.family; fontSize: root.pointSize
        cellWidth: root.cw; cellHeight: root.ch; ascent: 10
        drawScale: root.scale
    }
}'''
(ARGS.output / 'fixture.qml').write_text(QML)


def flush(seconds=.08):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        APP.processEvents()
        time.sleep(.001)


def until(predicate, seconds=4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        APP.processEvents()
        if predicate():
            return
        time.sleep(.001)
    raise AssertionError('Native fixture deadline')


def value(screen, sequence=1, attempt=1, generation=1, **extra):
    rows = [dict(runs=screen.runs(r)) for r in range(screen.rows)]
    return dict(generation=generation, attempt=attempt, sequence=sequence, columns=screen.columns,
        rowCount=screen.rows, rows=rows, changedRuns=[dict(row=r, **run) for r in range(screen.rows) for run in rows[r]['runs']],
        readiness='partial', lifecycle='running', **extra)


def message(frame, revision=1, consumer='fixture', generation=1):
    return json.dumps(dict(consumerId=consumer, snapshot=dict(generation=generation, revision=revision,
        observedMonotonicMs=revision, state='ready', value=dict({k:v for k,v in frame.items() if k != 'changedRuns'}, rowFormat=frame.get('rowFormat', 'full-v1')) if 'rows' in frame else frame, error='')), ensure_ascii=False) + '\n'


def pixels(image):
    return bytes(image.constBits())


class NativeTerminal(unittest.TestCase):
    def setUp(self):
        self.warnings = []
        self.view = QQuickView()
        self.view.engine().addImportPath(str(ROOT / 'widgets/qml'))
        self.view.engine().addImportPath(str(ARGS.import_path))
        self.view.engine().warnings.connect(lambda errors: self.warnings.extend(str(error) for error in errors))
        self.view.setSource(QUrl.fromLocalFile(str(ARGS.output / 'fixture.qml')))
        self.assertNotEqual(self.view.status(), QQuickView.Status.Error, self.view.errors())
        self.view.show()
        self.root = self.view.rootObject()
        self.surface = self.root.findChild(QObject, 'surface')
        self.root.subscribe('fixture', 1)

    def tearDown(self):
        if self.view is not None:
            self.view.close()
            shiboken6.delete(self.view)
        flush(.03)
        self.assertEqual(self.warnings, [])

    def publish(self, frame, revision=1):
        self.root.feed(message(frame, revision))
        until(lambda: self.surface.property('diagnostics').get('revision') == revision)
        flush(.025)

    def test_wire_patches_atomic_base_and_pixel_equivalence(self):
        from blox_widgets.broker import OutputQueue
        queue = OutputQueue()
        screen = AnsiScreen(4, 12)
        def wire(frame, revision):
            queue.emit(dict(_terminal=True, consumerId='fixture', snapshot=dict(generation=1,
                revision=revision, observedMonotonicMs=revision, state='ready', error='', value=frame)))
            line = queue.chunk(); queue.advance(len(line)); return line.decode()
        screen.feed('界A\r\x1b[P'.encode())
        first = wire(value(screen), 1)
        self.root.feed(first)
        until(lambda: self.surface.property('diagnostics').get('revision') == 1)
        screen.feed(b'\x1b[2;1H\x1b[41mRED\x1b[0m')
        second = wire(value(screen, 4), 7)
        self.assertEqual(json.loads(second)['snapshot']['value']['rowFormat'], 'patch-v1')
        self.root.feed(second)
        until(lambda: self.surface.property('diagnostics').get('revision') == 7)
        flush(); patched = pixels(self.view.grabWindow())
        # Force a normal full keyframe of identical cells, compare exact pixels.
        self.root.feed(message(value(screen, 4), 8))
        until(lambda: self.surface.property('diagnostics').get('revision') == 8)
        flush(); self.assertEqual(patched, pixels(self.view.grabWindow()))
        # A wrong base and a late invalid row must leave the staged base intact.
        queue.wire_bases.clear()
        wire(value(screen, 4), 8)
        screen.feed(b'\x1b[2;1H\x1b[2K')
        valid = json.loads(wire(value(screen, 5), 12))
        failures = self.root.property('failures')
        for mutate in ('baseRevision', 'baseSequence', 'attempt', 'columns', 'generation'):
            bad = copy.deepcopy(valid); bad['snapshot']['value'][mutate] += 1
            self.root.feed(json.dumps(bad)+'\n')
            self.assertEqual(self.root.property('messages'), 3)
        bad = copy.deepcopy(valid)
        bad['snapshot']['value']['rowPatches'] = [[0, value(screen)['rows'][0]], [1, {'runs':[]}]]
        self.root.feed(json.dumps(bad)+'\n')
        self.assertGreater(self.root.property('failures'), failures)
        self.root.feed(json.dumps(valid)+'\n')
        until(lambda: self.surface.property('diagnostics').get('revision') == 12)
        flush(); cleared = pixels(self.view.grabWindow())
        self.root.feed(message(value(screen, 5), 13))
        until(lambda: self.surface.property('diagnostics').get('revision') == 13)
        flush(); self.assertEqual(cleared, pixels(self.view.grabWindow()))

    def test_patch_requires_base_and_survives_reentrant_unsubscribe(self):
        from blox_widgets.broker import OutputQueue
        queue=OutputQueue(); screen=AnsiScreen(2,8)
        def encode(revision):
            queue.emit(dict(_terminal=True,consumerId='fixture',snapshot=dict(generation=1,
                revision=revision,observedMonotonicMs=revision,state='ready',error='',value=value(screen,revision))))
            raw=queue.chunk(); queue.advance(len(raw)); return raw.decode()
        first=encode(1); screen.feed(b'NEW'); patch=encode(2)
        self.root.feed(patch)
        self.assertEqual(self.root.property('messages'),0)
        self.assertEqual(self.root.property('failures'),1)
        legacy=json.loads(first); legacy['snapshot']['value'].pop('rowFormat')
        self.root.feed(json.dumps(legacy)+'\n')
        self.assertEqual(self.root.property('messages'),0)
        self.root.feed(first)
        until(lambda:self.surface.property('diagnostics').get('revision')==1)
        self.root.setProperty('callbackSignal','frame')
        self.root.setProperty('callbackAction','unsubscribe')
        self.root.feed(patch)
        flush()
        self.assertEqual(self.root.property('callbackHits'),1)
        self.assertFalse(self.surface.property('contentReady'))

    def test_validation_precedes_adoption_and_drops_unknown_cells(self):
        screen = AnsiScreen(4, 8); screen.feed(b'FIRST')
        self.publish(value(screen))
        first = pixels(self.view.grabWindow())
        self.root.setProperty('adopt', False)
        screen.feed(b'\rOTHER')
        second = value(screen, 2)
        self.root.feed(message(second, 2))
        flush()
        self.assertEqual(self.surface.property('diagnostics')['revision'], 1)
        self.assertTrue(pixels(self.view.grabWindow()) == first)
        before = self.root.property('messages')
        for invalid in (message(second, 1), message(second, 3, generation=2), message(second, 3, consumer='hidden')):
            self.root.feed(invalid)
        self.assertEqual(self.root.property('messages'), before)
        meta = self.root.property('lastMessage')['snapshot']['value']
        self.assertNotIn('rows', meta); self.assertNotIn('changedRuns', meta)
        self.assertEqual(meta['nonblankCells'], 5)
        self.root.acceptLast()
        until(lambda: self.surface.property('diagnostics').get('revision') == 2)
        flush()
        self.assertTrue(pixels(self.view.grabWindow()) != first)

    def test_coalesced_erasures_attempts_and_cancelled_models(self):
        screen = AnsiScreen(4, 8); screen.feed(b'\x1b[41m    \x1b[2;1H\x1b[44m    \x1b[0m')
        self.publish(value(screen))
        screen.feed(b'\x1b[1;1H\x1b[2K')
        skipped = value(screen, 2)
        screen.feed(b'\x1b[2;1H\x1b[2K')
        latest = value(screen, 5)
        self.root.feed(message(skipped, 2) + message(latest, 5))
        until(lambda: self.surface.property('diagnostics').get('revision') == 5)
        flush()
        image = self.view.grabWindow()
        dpr = self.view.devicePixelRatio()
        self.assertEqual(image.pixelColor(int(2*dpr), int(2*dpr)).name(), '#112233')
        self.assertEqual(image.pixelColor(int(2*dpr), int(15*dpr)).name(), '#112233')
        screen.feed(b'NEW')
        self.publish(value(screen, 1, attempt=2), 6)
        self.root.unsubscribe('fixture')
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        self.assertFalse(self.surface.property('diagnostics')['hasImage'])
        self.root.acceptLast() # An expired opaque token must be safe to replay.
        flush()
        self.assertFalse(self.surface.property('contentReady'))

    def test_hidden_view_has_no_render_work(self):
        screen = AnsiScreen(4, 8)
        self.publish(value(screen))
        self.surface.setProperty('visible', False)
        count = self.surface.property('diagnostics')['completedFrames']
        for seq in range(2, 62):
            screen.feed(('\r%07d' % seq).encode())
            self.root.feed(message(value(screen, seq), seq))
        flush(.15)
        self.assertEqual(self.surface.property('diagnostics')['completedFrames'], count)
        self.surface.setProperty('visible', True)
        until(lambda: self.surface.property('diagnostics').get('revision') == 61)

    def test_actual_primary_allocation_and_geometry(self):
        screen = AnsiScreen(1, 2)
        self.publish(value(screen))
        for index, (cw, ch, scale) in enumerate([(8.25, 13.5, .73), (30000, 17000, 3), (65536, 1, 2)], 2):
            self.root.setProperty('cw', cw); self.root.setProperty('ch', ch); self.root.setProperty('scale', scale)
            until(lambda: abs(self.surface.property('displayWidth') - 2*cw*scale) < .001)
            flush(.15)
            stats = self.surface.property('diagnostics')
            w, h = stats['rasterWidth'], stats['rasterHeight']
            self.assertLessEqual(w, 8192); self.assertLessEqual(h, 8192)
            self.assertLessEqual(w*h, 16777216)
            self.assertEqual(stats['allocatedBytes'], stats['bytesPerLine'] * h)
            self.assertLessEqual(stats['allocatedBytes'], 64*1024*1024)
            self.assertEqual(stats['dpr'], self.view.devicePixelRatio())
        OBSERVATIONS['allocation'] = stats

    def test_real_host_first_image_readiness_and_cancellation(self):
        self.root.makeHost()
        until(lambda: bool(self.root.property('hostId')))
        host = self.root.property('host')
        self.assertEqual(host.property('phase'), 'preparing')
        generation = self.root.property('hostGeneration')
        screen = AnsiScreen(4, 8); screen.feed('界e\u0301'.encode())
        self.root.feed(message(value(screen, generation=generation), consumer=self.root.property('hostId'), generation=generation))
        until(lambda: host.property('phase') == 'visible')
        host.setProperty('visible', False)
        until(lambda: host.property('phase') == 'hidden')

    def test_canvas_visual_reference(self):
        screen = AnsiScreen(5, 18)
        screen.feed(('ASCII \x1b[31mred\x1b[0m\r\n界e\u0301 𐍈\r\n'
                     '\x1b[44;1;4mBOLD under\x1b[0m\r\n\x1b[7mINVERSE\x1b[0m\r\n█▓░ πЖअ😀').encode())
        frame = value(screen)
        diffs = []
        cases = [(family, origin, cw, ch, scale) for family in ('monospace', 'DejaVu Sans Mono')
            for origin, cw, ch, scale in [(0,8,13,1),(.25,8.25,13.5,1),(.375,8.25,13.5,.73)]]
        for i, (family, origin, cw, ch, scale) in enumerate(cases):
            self.root.setProperty('reference', False)
            self.root.setProperty('family', family)
            self.root.setProperty('origin', origin); self.root.setProperty('cw', cw)
            self.root.setProperty('ch', ch); self.root.setProperty('scale', scale)
            frame['sequence'] = i + 1
            self.publish(frame, i + 1)
            native = self.view.grabWindow()
            self.root.setProperty('referenceFrame', frame)
            self.root.setProperty('reference', True)
            flush(.2)
            reference = self.view.grabWindow()
            native.save(str(ARGS.output / f'native-{i}.png'))
            reference.save(str(ARGS.output / f'canvas-{i}.png'))
            a, b = pixels(native), pixels(reference)
            differing = sum(a[j:j+4] != b[j:j+4] for j in range(0,len(a),4))
            maximum = max(abs(x-y) for x,y in zip(a,b))
            diffs.append(dict(fontFamily=family,origin=origin,cellWidth=cw,cellHeight=ch,scale=scale,differingPixels=differing,maximumChannelDifference=maximum))
        OBSERVATIONS['parity'] = diffs
        # Keep a measured report even when this acceptance check fails.
        # Qt's two image-node paths can differ by one rounding level at
        # fractional DPR. Larger raster or clipping changes are not accepted.
        self.assertTrue(all(row['maximumChannelDifference'] <= 1 for row in diffs), diffs)

    def test_fragmented_stream_bounds_and_reentrant_clear(self):
        screen = AnsiScreen(1, 2); screen.feed('𐍈'.encode())
        base = json.loads(message(value(screen)))
        template = json.dumps(dict(padding='', **base), ensure_ascii=False)
        # Put a surrogate pair across the native UTF-16 conversion block edge.
        padding = 'x' * (65535 - template.index('𐍈'))
        wire = json.dumps(dict(padding=padding, **base), ensure_ascii=False) + '\n'
        self.root.feed(wire[:37]); self.root.feed(wire[37:])
        until(lambda: self.surface.property('contentReady'))
        self.assertEqual(self.root.property('lastMessage')['snapshot']['value']['nonblankCells'], 1)
        before = self.root.property('messages')
        self.root.setProperty('clearOnMessage', True)
        self.root.feed('{"requestId":1,"ok":true}\n{"requestId":2,"ok":true}\n')
        self.assertEqual(self.root.property('messages'), before + 1)
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        self.root.subscribe('fixture', 1)
        self.root.feed('x' * (8 * 1024 * 1024 + 1))
        self.assertEqual(self.root.property('failures'), 1)
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])

    def test_bad_grid_is_atomic_and_glyph_cache_is_bounded(self):
        screen = AnsiScreen(2, 8); screen.feed(b'valid')
        self.publish(value(screen))
        bad = value(screen, 2)
        bad['rows'][0]['runs'][0]['cells'][0] = 17
        self.root.feed(message(bad, 2))
        self.assertEqual(self.root.property('failures'), 1)
        self.assertEqual(self.surface.property('diagnostics')['revision'], 1)
        self.assertTrue(self.surface.property('contentReady'))
        before = self.root.property('messages')
        self.root.feed(json.dumps(dict(consumerId='fixture', snapshot=[bad])) + '\n')
        self.assertEqual(self.root.property('messages'), before)
        self.assertEqual(self.root.property('failures'), 2)
        screen = AnsiScreen(50, 240)
        frame = value(screen, 3)
        for r, row in enumerate(frame['rows']):
            row['runs'][0]['cells'] = [f'{r*240+c:04x}' for c in range(240)]
        # changedRuns is deliberately not used by the native retained-row route.
        frame['changedRuns'] = []
        self.publish(frame, 3)
        stats = self.surface.property('diagnostics')
        self.assertLessEqual(stats['glyphCacheBytes'], stats['glyphCacheByteLimit'])
        self.assertLessEqual(stats['glyphCacheEntries'], stats['glyphCacheEntryLimit'])
        self.assertLess(stats['glyphCacheEntries'], 12000)
        self.assertLessEqual(stats['liveModels'], 4)
        OBSERVATIONS['cache'] = stats

    def test_ansi_edits_preserve_placeholder_geometry_and_pixels(self):
        styled = '\x1b[44;1;4m界e\u0301界A\x1b[0m'
        cases = [('delete_at_zero', '界A\r\x1b[P'),
                 ('delete_consecutive', '界界\r\x1b[P\x1b[2G\x1b[P'),
                 ('combine_after_delete', '界界\r\x1b[P\x1b[2G\x1b[P\u0301'),
                 ('insert_truncates_wide', '12345界A\r\x1b[2@'),
                 ('resize_clips_wide', '123456界'),
                 ('resize_grows_orphan', '界A\r\x1b[P')]
        for name, edit in [('delete_lead', '\r\x1b[P'), ('delete_continuation', '\x1b[2G\x1b[P'),
                           ('delete_combining', '\x1b[3G\x1b[P'), ('delete_across', '\r\x1b[4P'),
                           ('insert_lead', '\r\x1b[@'), ('insert_continuation', '\x1b[2G\x1b[2@'),
                           ('erase_lead', '\r\x1b[X'), ('erase_continuation', '\x1b[2G\x1b[X'),
                           ('overwrite_continuation', '\x1b[2Gx'), ('erase_prefix', '\r\x1b[1K'),
                           ('insert_line', '\r\x1b[L'), ('delete_line', '\r\x1b[M'),
                           ('alternate_buffer', '\x1b[?1049h界e\u0301\r\x1b[P\x1b[?1049l')]:
            cases.append((name, styled + edit))
        observations = []
        for revision, (name, text) in enumerate(cases, 1):
            with self.subTest(operation=name):
                screen = AnsiScreen(2, 8); screen.feed(text.encode())
                if name == 'resize_clips_wide': screen.resize(7, 2)
                if name == 'resize_grows_orphan': screen.resize(9, 3)
                frame = value(screen, revision)
                retained = copy.deepcopy(frame['rows'])
                self.root.setProperty('reference', False)
                self.publish(frame, revision)
                native = self.view.grabWindow()
                self.root.setProperty('referenceFrame', frame)
                self.root.setProperty('reference', True)
                flush(.04)
                reference = self.view.grabWindow()
                maximum = max(abs(a-b) for a,b in zip(pixels(native), pixels(reference)))
                self.assertLessEqual(maximum, 1)
                self.assertEqual(frame['rows'], retained)
                self.assertEqual(self.root.property('failures'), 0)
                observations.append(dict(operation=name, cells=screen.cells, maximumChannelDifference=maximum))
        OBSERVATIONS['ansiEdits'] = observations

    def test_placeholders_do_not_relax_other_grid_validation(self):
        screen = AnsiScreen(2, 8); screen.feed('界A\r\x1b[P'.encode())
        good = value(screen)
        self.publish(good)
        mutations = [lambda f: f['rows'][0]['runs'][0]['cells'].__setitem__(0, 17),
                     lambda f: f['rows'][0]['runs'][0]['cells'].__setitem__(0, 'a'*9),
                     lambda f: f['rows'][0]['runs'][0].__setitem__('column', 1),
                     lambda f: f['rows'][0]['runs'][0].__setitem__('bold', 'true'),
                     lambda f: f['rows'][0]['runs'][0].__setitem__('foreground', 'not-a-colour'),
                     lambda f: f['rows'][0].__setitem__('runs', []),
                     lambda f: f.__setitem__('rowCount', 3),
                     lambda f: f.__setitem__('columns', 0),
                     lambda f: f.__setitem__('attempt', 0),
                     lambda f: f.__setitem__('sequence', 1.5)]
        for mutation in mutations:
            bad = copy.deepcopy(good); mutation(bad)
            before = self.root.property('messages')
            errors = self.root.property('failures')
            self.root.feed(message(bad, 2))
            self.assertEqual(self.root.property('messages'), before)
            self.assertEqual(self.root.property('failures'), errors + 1)
            self.assertEqual(self.surface.property('diagnostics')['revision'], 1)
            self.assertTrue(self.surface.property('contentReady'))

    def arm(self, signal, action, consumer='fixture', frame=None):
        self.root.setProperty('callbackSignal', signal)
        self.root.setProperty('callbackConsumer', consumer)
        self.root.setProperty('callbackFrame', frame or {})
        self.root.setProperty('callbackAction', action)

    def test_reentrant_unsubscribe_and_clear_cannot_restore_expired_frames(self):
        observations = []
        for index, (signal, action, transition) in enumerate(
                [('notReady', 'unsubscribe', kind) for kind in ('replacement', 'columns', 'rows', 'attempt', 'generation')]
                + [(signal, action, 'columns') for signal in ('notReady', 'width', 'height', 'geometry', 'grid', 'diagnostics', 'ready')
                   for action in ('unsubscribe', 'clear')]):
            with self.subTest(signal=signal, action=action, transition=transition):
                self.root.setProperty('callbackAction', '')
                self.root.subscribe('fixture', 1)
                screen = AnsiScreen(2, 8); screen.feed(b'OLD')
                self.publish(value(screen))
                consumer = 'replacement' if transition in ('replacement', 'generation') else 'fixture'
                generation = 2 if transition == 'generation' else 1
                if consumer != 'fixture' or generation != 1:
                    self.root.subscribe(consumer, generation)
                if transition == 'columns': screen.resize(9, 2)
                if transition == 'rows': screen.resize(8, 3)
                next_frame = value(screen, 2, attempt=2 if transition == 'attempt' else 1, generation=generation)
                before = self.root.property('callbackHits')
                self.arm(signal, action, consumer)
                self.root.feed(message(next_frame, 2, consumer=consumer, generation=generation))
                until(lambda: self.root.property('callbackHits') == before + 1)
                expired = copy.deepcopy(self.root.property('lastMessage')['snapshot']['value'])
                flush(.04)
                stats = self.surface.property('diagnostics')
                self.assertFalse(stats['hasFrame']); self.assertFalse(stats['hasImage'])
                completed = stats['completedFrames']
                self.surface.setProperty('frame', expired)
                flush(.04)
                self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
                self.assertFalse(self.surface.property('contentReady'))
                self.assertEqual(self.surface.property('diagnostics')['completedFrames'], completed)
                observations.append(dict(signal=signal, action=action, transition=transition, expiredFrameRejected=True))
        OBSERVATIONS['expiredAdoptions'] = observations

    def test_nested_adoption_wins_each_synchronous_notification(self):
        for signal in ('notReady', 'width', 'height', 'geometry', 'grid', 'diagnostics', 'frame', 'ready', 'appearance'):
            with self.subTest(signal=signal):
                self.root.setProperty('callbackAction', '')
                self.root.resetAdoption()
                self.root.subscribe('fixture', 1)
                screen = AnsiScreen(2, 8); screen.feed(b'OLD')
                self.publish(value(screen))
                self.root.setProperty('adopt', False)
                self.root.subscribe('candidate', 2); self.root.subscribe('winner', 3)
                candidate = AnsiScreen(3, 9); candidate.feed(b'REJECTED')
                self.root.feed(message(value(candidate, generation=2), 40, consumer='candidate', generation=2))
                pending = copy.deepcopy(self.root.property('lastMessage')['snapshot']['value'])
                winner = AnsiScreen(4, 10); winner.feed('界e\u0301'.encode())
                self.root.feed(message(value(winner, attempt=4, generation=3), 99, consumer='winner', generation=3))
                accepted = copy.deepcopy(self.root.property('lastMessage')['snapshot']['value'])
                before = self.root.property('callbackHits')
                self.arm(signal, 'replace', frame=accepted)
                if signal == 'appearance':
                    self.surface.setProperty('fontSize', self.surface.property('fontSize') + 1)
                else:
                    self.surface.setProperty('frame', pending)
                until(lambda: self.root.property('callbackHits') == before + 1)
                until(lambda: self.surface.property('diagnostics').get('revision') == 99)
                self.assertEqual(self.surface.property('frame'), accepted)
                self.assertEqual(self.surface.property('gridWidth'), 10*self.root.property('cw'))
                self.root.unsubscribe('winner')
                flush(.03)
                self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        OBSERVATIONS['nestedAdoptionSignals'] = ['notReady', 'width', 'height', 'geometry', 'grid', 'diagnostics', 'frame', 'ready', 'appearance']

    def test_reentrant_staging_does_not_adopt_an_obsolete_candidate(self):
        screen = AnsiScreen(2, 8); screen.feed(b'OLD')
        self.publish(value(screen))
        self.root.setProperty('adopt', False)
        self.root.subscribe('replacement', 2)
        self.root.feed(message(value(screen, generation=2), 40, consumer='replacement', generation=2))
        pending = copy.deepcopy(self.root.property('lastMessage')['snapshot']['value'])
        screen.feed(b'NEW')
        self.root.setProperty('callbackWire', message(value(screen, 2, generation=2), 41, consumer='replacement', generation=2))
        self.arm('notReady', 'stage')
        self.surface.setProperty('frame', pending)
        flush(.04)
        self.assertEqual(self.root.property('callbackHits'), 1)
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        self.assertFalse(self.surface.property('contentReady'))
        latest = self.root.property('lastMessage')['snapshot']['value']
        self.assertEqual(latest['frameRevision'], 41)
        self.surface.setProperty('frame', latest)
        until(lambda: self.surface.property('diagnostics').get('revision') == 41)

    def test_property_notifications_survive_reentrant_clear(self):
        signals = []
        self.surface.appearanceChanged.connect(lambda: signals.append(True))
        for name, changed in [('fontFamily', 'DejaVu Sans Mono'), ('fontSize', 13), ('cellWidth', 9), ('cellHeight', 14)]:
            with self.subTest(property=name):
                self.root.resetAdoption(); self.root.subscribe('fixture', 1)
                self.publish(value(AnsiScreen(2, 8)))
                signals.clear()
                before = self.root.property('callbackHits')
                self.arm('geometry', 'clear')
                self.surface.setProperty(name, changed)
                self.assertEqual(self.root.property('callbackHits'), before + 1)
                self.assertGreater(len(signals), 0)
                self.assertEqual(self.surface.property(name), changed)
                self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
                self.assertFalse(self.surface.property('contentReady'))

    def test_reentrant_empty_frame_cancels_outer_adoption(self):
        screen = AnsiScreen(2, 8); screen.feed(b'OLD')
        self.publish(value(screen))
        self.root.setProperty('adopt', False)
        self.root.subscribe('replacement', 1)
        self.root.feed(message(value(screen), 2, consumer='replacement'))
        pending = self.root.property('lastMessage')['snapshot']['value']
        self.arm('notReady', 'empty')
        self.surface.setProperty('frame', pending)
        flush(.04)
        self.assertEqual(self.root.property('callbackHits'), 1)
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        self.assertFalse(self.surface.property('diagnostics')['hasImage'])
        # The token is still live. Only a fresh explicit adoption may use it.
        self.surface.setProperty('frame', pending)
        until(lambda: self.surface.property('diagnostics').get('revision') == 2)

    def test_generation_revision_attempt_and_token_guards(self):
        screen = AnsiScreen(2, 8); screen.feed('界e\u0301'.encode())
        self.publish(value(screen, attempt=2))
        old = copy.deepcopy(self.surface.property('frame'))
        first = pixels(self.view.grabWindow())
        self.root.setProperty('adopt', False)
        screen.feed(b'NEW')
        self.root.feed(message(value(screen, 2, attempt=2), 2))
        latest = copy.deepcopy(self.root.property('lastMessage')['snapshot']['value'])
        before = self.root.property('messages')
        for stale in (message(value(screen, 1, attempt=1), 3), message(value(screen, 1, attempt=2), 3),
                      message(value(screen, 3, attempt=2, generation=2), 3, generation=2),
                      message(value(screen, 2, attempt=2), 1)):
            self.root.feed(stale)
        self.assertEqual(self.root.property('messages'), before)
        for key, bad in [('frameToken', 'expired-token'), ('generation', 2), ('attempt', 3), ('frameRevision', 3)]:
            invalid = dict(latest, **{key: bad})
            self.surface.setProperty('frame', invalid)
            self.assertEqual(self.surface.property('frame'), old)
        self.surface.setProperty('frame', old)
        flush(.03)
        self.assertEqual(self.surface.property('diagnostics')['revision'], 1)
        self.assertEqual(pixels(self.view.grabWindow()), first)
        self.surface.setProperty('frame', latest)
        until(lambda: self.surface.property('diagnostics').get('revision') == 2)
        self.root.subscribe('fixture', 2)
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        self.surface.setProperty('frame', latest)
        self.assertFalse(self.surface.property('diagnostics')['hasFrame'])
        self.root.feed(message(value(screen, generation=2), 1, generation=2))
        fresh = self.root.property('lastMessage')['snapshot']['value']
        self.assertNotEqual(fresh['frameToken'], latest['frameToken'])
        self.surface.setProperty('frame', fresh)
        until(lambda: self.surface.property('contentReady'))

    def destroy_surface_on(self, signal, initially_ready):
        screen = AnsiScreen(2, 8); screen.feed(b'OLD')
        if initially_ready: self.publish(value(screen))
        destroyed = []
        def destroy():
            if not destroyed:
                destroyed.append(True)
                shiboken6.delete(self.surface)
        getattr(self.surface, signal).connect(destroy)
        screen.resize(9, 2)
        self.root.feed(message(value(screen, 2), 2))
        until(lambda: bool(destroyed))
        flush(.06)
        self.assertFalse(shiboken6.isValid(self.surface))

    def test_surface_destruction_during_discard(self):
        self.destroy_surface_on('contentReadyChanged', True)

    def test_surface_destruction_during_geometry(self):
        self.destroy_surface_on('widthChanged', False)

    def test_surface_destruction_during_first_image_notification(self):
        self.destroy_surface_on('contentReadyChanged', False)

    def test_engine_destruction_cancels_pending_work(self):
        screen = AnsiScreen(50, 240); screen.feed('界e\u0301'.encode())
        self.root.feed(message(value(screen)))
        self.view.close(); shiboken6.delete(self.view); self.view = None
        flush(.06)
        self.assertFalse(shiboken6.isValid(self.surface))


if __name__ == '__main__':
    suite = (unittest.TestSuite(NativeTerminal(name) for name in ARGS.case) if ARGS.case
             else unittest.defaultTestLoader.loadTestsFromTestCase(NativeTerminal))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    OBSERVATIONS.update(dpr=ARGS.dpr, testsRun=result.testsRun, failures=len(result.failures), errors=len(result.errors),
        referenceSha256=hashlib.sha256(ARGS.reference_canvas.read_bytes()).hexdigest())
    (ARGS.output / 'result.json').write_text(json.dumps(OBSERVATIONS, indent=2) + '\n')
    sys.exit(not result.wasSuccessful())
