"""Focused offscreen native renderer checks. No provider, desktop or GPU.

python widgets/tests/render_terminal_scale.py --output-directory /tmp/terminal-scale
Runs isolated software readbacks at DPR 1, 1.25, 1.5 and 2, with a deliberately proportional
'Blox monospace' substitution, a real mono family, and native-size text reference.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

# Reuse the existing fixture's private, display-free Qt environment.
import render_terminal
from PySide6.QtCore import QObject, QUrl
from PySide6.QtGui import QFont, QFontInfo, QFontMetricsF, QGuiApplication
from PySide6.QtQuick import QQuickView
from PIL import Image, ImageChops, ImageStat

WIDGETS = Path(__file__).resolve().parents[1]


def variant(value):
    return value.toVariant() if hasattr(value, "toVariant") else value


def pixels(image):
    return Image.fromqimage(image).convert("RGB")


def run(dpr, output):
    os.environ["QT_SCALE_FACTOR"] = str(dpr)
    QFont.insertSubstitution("Blox monospace", "DejaVu Sans")
    app = QGuiApplication([])
    mono = QFontInfo(QFont("monospace")).family()
    assert QFontMetricsF(QFont(mono)).horizontalAdvance("M") == QFontMetricsF(QFont(mono)).horizontalAdvance("i")
    assert not QFontInfo(QFont("Blox monospace")).fixedPitch()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="blox-terminal-scale-") as temporary:
        source = Path(temporary) / "Fixture.qml"
        source.write_text('''import QtQuick
import "NATIVE" as Native
import "WIDGETS" as Widgets
import "FIXTURES" as Fixtures
import Blox.Widgets.Terminal 1.0
Rectangle {
    id: fixture
    width: 960; height: 480; color: "#112233"
    property var observation: ({})
    property var nativeObservation: ({})
    Fixtures.TerminalFixtureDecoder { id: decoder }
    onObservationChanged: if (observation.value) nativeObservation = decoder.adapt("fixture", observation)
    property bool shown: true
    property bool full: false
    property string family: "Blox monospace"
    property real size: 14
    property bool compact: false
    Widgets.WidgetTheme { id: widgetTheme; monospaceFamily: fixture.family; fontSize: fixture.size }
    Native.TerminalView {
        id: terminal; objectName: "terminal"; anchors.fill: parent
        theme: widgetTheme; snapshot: parent.nativeObservation; fullscreen: parent.full; visible: parent.shown
        context: ({fullscreenMode: "fit", scrollbars: "hide", presentation: parent.compact ? "compact" : "normal"})
    }
    // A second route rasterises a large font directly, with no draw transform.
    TerminalSurface {
        objectName: "reference"; visible: false
        frame: visible ? terminal.frameData : ({}); fontFamily: terminal.textFamily
        fontSize: terminal.textSize * terminal.fitScale
        cellWidth: terminal.cellWidth * terminal.fitScale
        cellHeight: terminal.cellHeight * terminal.fitScale
        ascent: terminal.cellHeight // Python sets this to the measured baseline.
    }
}
'''.replace("NATIVE", (WIDGETS / "qml/Blox/Widgets/Native").as_uri())
            .replace("WIDGETS", (WIDGETS / "qml/Blox/Widgets").as_uri())
            .replace("FIXTURES", (WIDGETS / "tests/fixtures").as_uri()))
        view = QQuickView()
        view.engine().addImportPath(os.environ.get("BLOX_WIDGETS_IMPORT_PATH", str(WIDGETS / "qml")))
        view.setResizeMode(QQuickView.ResizeMode.SizeRootObjectToView)
        view.setSource(QUrl.fromLocalFile(str(source)))
        assert view.status() != QQuickView.Status.Error, view.errors()
        view.show()
        root = view.rootObject()
        terminal = root.findChild(QObject, "terminal")
        reference = root.findChild(QObject, "reference")
        canvas = terminal.findChild(QObject, "terminalCanvas")
        paints = []
        last_completed = [0]
        def painted():
            stats = canvas.property("diagnostics")
            if stats["completedFrames"] != last_completed[0] and stats.get("paintedRows", 0): paints.append(True)
            last_completed[0] = stats["completedFrames"]
        canvas.diagnosticsChanged.connect(painted)

        def flush():
            for _ in range(8):
                app.processEvents()
                time.sleep(.005)

        def capture(name=None):
            flush()
            active = reference if reference.property("visible") else canvas
            if root.property("shown") or reference.property("visible"):
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    app.processEvents()
                    stats = active.property("diagnostics")
                    if active.property("contentReady") and stats.get("appearanceRevision") == stats["desiredAppearanceRevision"]: break
                    time.sleep(.001)
                else: raise AssertionError("Native image preparation deadline")
            image = view.grabWindow()
            assert image.width() == round(view.width() * dpr), (image.width(), image.height(), view.width(), view.devicePixelRatio(), image.devicePixelRatio())
            result = pixels(image)
            if name:
                result.save(output / f"dpr{dpr}-{name}.png")
            return result

        rows = [dict(runs=[dict(column=0, cells=list("MWi 0e") + ["e\u0301", "界", "", "Z"],
                               foreground="#ffffff")]),
                dict(runs=[dict(column=0, cells=[" "] * 2, background="#cc241d"),
                           dict(column=2, cells=list("Bold"), bold=True, foreground="#00ff00", background="#cc241d"),
                           dict(column=6, cells=[" "] * 2, background="#cc241d"),
                           dict(column=8, cells=[" "] * 4, inverse=True, foreground="#458588")]),
                dict(runs=[dict(column=0, cells=list("underline   "), underline=True,
                               foreground="#ffcc00", background="#242424")]),
                dict(runs=[dict(column=0, cells=[" "] * 12, background="#8040a0")])]
        sequence = 0

        def send(changed=None, generation=1, skip=0):
            nonlocal sequence
            sequence += 1 + skip
            changed = range(len(rows)) if changed is None else changed
            root.setProperty("observation", dict(state="ready", revision=sequence, value=dict(
                sequence=sequence, generation=generation, columns=12, rowCount=4,
                rows=copy.deepcopy(rows), changedRuns=[dict(row=r) for r in changed])))

        send()
        assert terminal.property("requestedFamily") == "Blox monospace"
        normal = capture("normal")
        assert terminal.property("textFamily") == mono
        assert not terminal.property("fixedCellFont")
        font = QFont(mono)
        font.setPixelSize(round(terminal.property("textSize")))
        metrics = QFontMetricsF(font)
        assert abs(terminal.property("cellWidth") - metrics.horizontalAdvance("M")) < .01, (terminal.property("textSize"),terminal.property("cellWidth"),metrics.horizontalAdvance("M"),mono, terminal.property("textFamily"))
        assert metrics.horizontalAdvance("M") == metrics.horizontalAdvance("i")
        root.setProperty("family", mono)
        assert capture() == normal, "A real mono theme must keep the same rendering"
        assert terminal.property("textFamily") == mono
        assert terminal.property("fixedCellFont")
        # Font changes must remeasure method-derived advances, including
        # compact's fractional requested size rounded by QFont.pixelSize.
        root.setProperty("size", 21)
        capture()
        font.setPixelSize(21)
        assert abs(terminal.property("cellWidth") - QFontMetricsF(font).horizontalAdvance("M")) < .01, (terminal.property("textSize"), terminal.property("cellWidth"), QFontMetricsF(font).horizontalAdvance("M"))
        root.setProperty("size", 14)
        root.setProperty("compact", True)
        capture()
        assert terminal.property("textSize") == 12.6
        assert canvas.property("fontSize") == 13
        font.setPixelSize(13)
        assert abs(terminal.property("cellWidth") - QFontMetricsF(font).horizontalAdvance("M")) < .01, (terminal.property("textSize"), terminal.property("cellWidth"), QFontMetricsF(font).horizontalAdvance("M"))
        root.setProperty("compact", False)
        capture()
        font.setPixelSize(14)
        normal_size = canvas.property("diagnostics")
        root.setProperty("full", True)
        full = capture("fullscreen")
        scale = terminal.property("fitScale")
        assert scale > 4, (scale, terminal.property("cellHeight"), terminal.property("cellWidth"), canvas.property("gridHeight"), canvas.property("height"))
        assert canvas.property("scale") == 1
        assert abs(canvas.property("displayWidth") - canvas.property("gridWidth") * scale) < .001
        assert abs(canvas.property("displayHeight") - canvas.property("gridHeight") * scale) < .001
        assert canvas.property("width") == canvas.property("displayWidth")
        assert canvas.property("height") == canvas.property("displayHeight")
        backing = canvas.property("diagnostics")
        assert backing["dpr"] == dpr
        assert backing["rasterWidth"] >= normal_size["rasterWidth"] * scale - 2*dpr
        inset = terminal.property("padding")
        cw, ch = terminal.property("cellWidth"), terminal.property("cellHeight")

        def point(col, row, dx=.5, dy=.5):
            return (round((inset + (col + dx) * cw * scale) * dpr),
                    round((inset + (row + dy) * ch * scale) * dpr))

        assert full.getpixel(point(0, 1)) == (204, 36, 29)
        assert full.getpixel(point(10, 1)) == (69, 133, 136)
        bold_box = (*point(2, 1, 0, 0), *point(6, 2, 0, 0))
        assert any(g > 200 and r < 30 and b < 30 for r, g, b in full.crop(bold_box).get_flattened_data())
        assert full.getpixel(point(11, 3)) == (128, 64, 160), "Last grid cell must survive fit"
        # Unicode combining text and wide-cell glyphs remain nonempty; the
        # continuation cell is available to the wide glyph, then Z stays put.
        for col, span in ((6, 1), (7, 2), (9, 1)):
            box = (*point(col, 0, 0, 0), *point(col + span, 1, 0, 0))
            assert max(ImageStat.Stat(full.crop(box)).extrema[0]) > 200
        continuation = (*point(8, 0, 0, 0), *point(9, 1, 0, 0))
        assert max(ImageStat.Stat(full.crop(continuation)).extrema[0]) > 200
        assert full.getpixel(point(10, 0)) == (17, 34, 51), "Glyphs escaped their cells"
        assert full.getpixel(point(1, 2, .5, (metrics.ascent() + 1.5) / ch)) == (255, 204, 0)
        assert full.getpixel(point(1, 3, .5, .01)) == (128, 64, 160), "Underline must not leak rows"

        # Compare glyph pixels against a direct large-font native reference.
        reference.setProperty("x", inset)
        reference.setProperty("y", inset)
        reference.setProperty("ascent", metrics.ascent() * scale)
        terminal.setProperty("visible", False)
        reference.setProperty("visible", True)
        ref = capture("direct-large-font")
        # Avoid edge rounding and compare just the first ASCII glyph row.
        box = (*point(0, 0, .1, .05), *point(6, 1, 0, -.05))
        sharp_error = sum(ImageStat.Stat(ImageChops.difference(full.crop(box), ref.crop(box))).mean) / 3
        assert sharp_error < 3, sharp_error
        reference.setProperty("visible", False)
        terminal.setProperty("visible", True)
        # Model the old fit path by enlarging a native-resolution texture.
        canvas.setProperty("transformOrigin", 0)
        canvas.setProperty("drawScale", 1)
        canvas.setProperty("scale", scale)
        legacy = capture("texture-upscale")
        blurred_error = sum(ImageStat.Stat(ImageChops.difference(legacy.crop(box), ref.crop(box))).mean) / 3
        assert blurred_error > sharp_error + 2, (sharp_error, blurred_error)
        canvas.setProperty("drawScale", scale)
        canvas.setProperty("scale", 1)
        capture()

        # Fractional row boundaries exercise clipping and dirty-row clears.
        full_scale = scale
        view.resize(960, 477)
        capture("fractional-fit")
        scale = terminal.property("fitScale")
        canvas.setProperty("drawScale", scale)
        capture()
        assert not (ch * scale).is_integer()
        # Incremental clearing must match a complete repaint, including row
        # edges at a fractional scale, coloured spaces and underlines.
        patterns = copy.deepcopy(rows)
        rows[1] = dict(runs=[])
        send([1])
        incremental = capture("row-cleared")
        def invalidate():
            current = canvas.property("ascent")
            canvas.setProperty("ascent", current + .001)
            canvas.setProperty("ascent", current)
        invalidate()
        full_repaint = capture("full-repaint")
        diff = ImageChops.difference(full_repaint, incremental)
        assert full_repaint == incremental, ("Dirty-row result differs from full repaint", diff.getbbox(), ImageStat.Stat(diff).sum)
        dirty_comparisons = 1
        # Keep mixed styles in the neighbouring rows while changing one row
        # at several fractional fit scales. Every comparison uses a genuine
        # incremental paint followed by an explicit full repaint.
        for index in range(20):
            view.resize(960, 473 + index % 5)
            canvas.setProperty("drawScale", terminal.property("fitScale"))
            capture()
            row = index % 4
            rows[row] = dict(runs=[]) if index % 3 == 0 else copy.deepcopy(patterns[(index // 4 + row) % 4])
            send([row])
            incremental = capture()
            invalidate()
            full_repaint = capture()
            if incremental != full_repaint:
                incremental.save(output / f"dpr{dpr}-dirty-{index}.png")
                full_repaint.save(output / f"dpr{dpr}-full-{index}.png")
            assert incremental == full_repaint, ("Dirty-row/full mismatch", dpr, index)
            dirty_comparisons += 1
        scale = terminal.property("fitScale")
        for index in range(1000):
            send([2])
        assert canvas.property("diagnostics")["liveModels"] <= 6
        capture()
        before = len(paints)
        flush()
        assert len(paints) == before, "Static terminal schedules idle paints"
        send([])
        flush()
        assert len(paints) == before, "Empty delta schedules unnecessary paint"
        root.setProperty("shown", False)
        flush()
        before = len(paints)
        rows[3] = dict(runs=[])
        for index in range(20):
            send([3])
        flush()
        assert len(paints) == before, "Hidden updates paint unnecessarily"
        root.setProperty("shown", True)
        revealed = capture("reveal")
        assert revealed.getpixel(point(11, 3)) == (17, 34, 51)
        invalidate()
        assert capture() == revealed, "Reveal retained stale pixels"
        rows[0] = dict(runs=[])
        send([2], skip=1)
        skipped = capture()
        invalidate()
        assert capture() == skipped
        # Generation changes with otherwise consecutive sequence/revision
        # numbers must also recover all retained rows.
        rows[1] = dict(runs=[dict(column=0, cells=[" "] * 12, background="#cc241d")])
        send([2], generation=2)
        generation = capture()
        assert generation.getpixel(point(11, 1)) == (204, 36, 29)
        invalidate()
        assert capture() == generation
        # Same geometry, different font baseline must still invalidate.
        canvas.setProperty("ascent", metrics.ascent() - 2)
        capture()
        # Check pathological bounds while hidden, so the fixture allocates no
        # oversized image just to test the allocation arithmetic.
        root.setProperty("shown", False)
        flush()
        root.setProperty("full", False)
        root.setProperty("size", 100000)
        completed = canvas.property("diagnostics")["completedFrames"]
        flush()
        assert canvas.property("diagnostics")["completedFrames"] == completed
        report = dict(dpr=dpr, family=mono, cell=[cw, ch], fitScale=full_scale, fractionalFitScale=scale,
                       normalCanvas=[normal_size["logicalRasterWidth"], normal_size["logicalRasterHeight"]],
                       fullscreenCanvas=[backing["logicalRasterWidth"], backing["logicalRasterHeight"]],
                       physicalBacking=[backing["rasterWidth"], backing["rasterHeight"]],
                      grid=[12, 4], normalCellWidth=cw,
                      defaultFontMAdvance=QFontMetricsF(QFont()).horizontalAdvance("M"),
                      directReferenceMeanError=sharp_error, oldUpscaleMeanError=blurred_error,
                      dirtyFullComparisons=dirty_comparisons, idlePaints=0, hiddenPaints=0, passed=True)
        (output / f"dpr{dpr}.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report))
        canvas.diagnosticsChanged.disconnect(painted)
        view.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dpr", type=float, choices=[1, 1.25, 1.5, 2])
    parser.add_argument("--output-directory", type=Path, default=Path("/tmp/blox-terminal-scale"))
    args = parser.parse_args()
    if args.dpr:
        run(args.dpr, args.output_directory)
    else:
        for dpr in (1, 1.25, 1.5, 2):
            subprocess.run([sys.executable, __file__, "--dpr", str(dpr),
                            "--output-directory", str(args.output_directory)], check=True, timeout=25)
