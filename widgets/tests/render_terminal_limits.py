"""Real TerminalView allocation, displayed geometry and density resize checks.

python widgets/tests/render_terminal_limits.py --output-directory /tmp/terminal-limits
Uses the native surface's actual allocated QImage dimensions and sizeInBytes.
This measures the primary image, not total renderer memory or GPU residency.
Runs only the isolated offscreen software renderer, with a prebuilt private plugin.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

import render_terminal  # Owns the private, display-free Qt environment.
from PySide6.QtCore import QObject, QLoggingCategory, QtMsgType, QUrl, qInstallMessageHandler, qVersion
from PySide6.QtGui import QGuiApplication
from PySide6.QtQuick import QQuickView

WIDGETS = Path(__file__).resolve().parents[1]
DPRS = (1, 1.25, 1.5, 2)


def variant(value):
    return value.toVariant() if hasattr(value, "toVariant") else value


def run(dpr, output, case):
    os.environ["QT_SCALE_FACTOR"] = str(dpr)
    os.environ.pop("QT_CANVAS_OVERRIDE_DEVICEPIXELRATIO", None)
    app = QGuiApplication([])
    allocations, diagnostics, results, errors = [], [], [], []

    def message_handler(kind, context, message):
        print(message, file=sys.stderr)
        if kind in (QtMsgType.QtWarningMsg, QtMsgType.QtCriticalMsg, QtMsgType.QtFatalMsg): errors.append(message)

    previous_handler = qInstallMessageHandler(message_handler)
    output.mkdir(parents=True, exist_ok=True)
    prefix = f"dpr{dpr:g}-{case}"
    report = dict(qtVersion=qVersion(), dpr=dpr, backend="offscreen/software", results=results,
                  primaryImagePixelLimit=16777216, primaryImageSideLimit=8192,
                  allocationEvidence="Native actual QImage width/height/bytesPerLine/sizeInBytes",
                  sourceSha256={str(path.relative_to(WIDGETS)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (WIDGETS / "native/terminal.cpp",
                                             WIDGETS / "qml/Blox/Widgets/Native/TerminalView.qml")})
    view = QQuickView()
    view.engine().addImportPath(os.environ.get("BLOX_WIDGETS_IMPORT_PATH", str(WIDGETS / "qml")))
    try:
        with tempfile.TemporaryDirectory(prefix="blox-terminal-limits-") as temporary:
            source = Path(temporary) / "Fixture.qml"
            source.write_text('''import QtQuick
import "NATIVE" as Native
import "WIDGETS" as Widgets
import "FIXTURES" as Fixtures
Rectangle {
    id: fixture
    width: 1000; height: 800; color: "#112233"
    property var observation: ({})
    property var nativeObservation: ({})
    Fixtures.TerminalFixtureDecoder { id: decoder }
    onObservationChanged: if (observation.value) nativeObservation = decoder.adapt("fixture", observation)
    property real size: 48
    property real density: 1
    property bool full: false
    property string mode: "scroll"
    Widgets.WidgetTheme { id: widgetTheme; fontSize: fixture.size; densityScale: fixture.density }
    Native.TerminalView {
        objectName: "terminal"; anchors.fill: parent
        theme: widgetTheme; snapshot: fixture.nativeObservation; fullscreen: fixture.full
        context: ({fullscreenMode: fixture.mode, scrollbars: "hide"})
        settings: ({columns: 240, rows: 50})
    }
}
'''.replace("NATIVE", (WIDGETS / "qml/Blox/Widgets/Native").as_uri())
                .replace("WIDGETS", (WIDGETS / "qml/Blox/Widgets").as_uri())
                .replace("FIXTURES", (WIDGETS / "tests/fixtures").as_uri()))
            view.setResizeMode(QQuickView.ResizeMode.SizeRootObjectToView)
            view.setSource(QUrl.fromLocalFile(str(source)))
            assert view.status() != QQuickView.Status.Error, view.errors()
            root = view.rootObject()
            terminal = root.findChild(QObject, "terminal")
            canvas = terminal.findChild(QObject, "terminalCanvas")
            canvas.setObjectName("terminalRaster")
            last_completed = [0]
            def allocated():
                stats = canvas.property("diagnostics")
                if stats["completedFrames"] != last_completed[0] and stats.get("paintedRows", 0) and stats["hasImage"]:
                    item = dict(width=stats["rasterWidth"], height=stats["rasterHeight"], bytes=stats["allocatedBytes"],
                        bytesPerLine=stats["bytesPerLine"], dpr=stats["dpr"])
                    allocations.append(item); diagnostics.append(json.dumps(item))
                last_completed[0] = stats["completedFrames"]
            canvas.diagnosticsChanged.connect(allocated)
            viewport = canvas.parentItem().parentItem()
            assert viewport.metaObject().indexOfProperty("contentX") >= 0
            view.show()

            def flush():
                for _ in range(10):
                    app.processEvents()
                    time.sleep(.005)

            revision = 0
            def send(columns, rows, sequence=1):
                nonlocal revision
                revision += 1
                root.setProperty("observation", dict(state="ready", revision=revision, value=dict(
                    sequence=sequence, generation=1, columns=columns, rowCount=rows,
                    rows=[dict(runs=[dict(column=0, cells=[" "] * 20, background="#cc241d"),
                                     dict(column=20, cells=[" "] * (columns - 20), background="#458588")])
                          for _ in range(rows)], changedRuns=[])))

            def capture(name):
                flush()
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    app.processEvents()
                    stats = canvas.property("diagnostics")
                    if (canvas.property("contentReady") and stats.get("appearanceRevision") == stats["desiredAppearanceRevision"]
                            and stats.get("revision") == revision): break
                    time.sleep(.001)
                else: raise AssertionError("Native image preparation deadline")
                image = view.grabWindow()
                assert not image.isNull()
                assert view.devicePixelRatio() == dpr
                image.save(str(output / f"{prefix}-{name}.png"))
                return image

            def check_image(name, since):
                # A new real allocation must have happened for this geometry.
                assert len(allocations) > since, "No actual native QImage allocation diagnostic"
                image = allocations[-1]
                results.append(dict(case=name, actualPrimaryImage=image.copy(),
                                    displayedGrid=[viewport.property("contentWidth"), viewport.property("contentHeight")]))
                assert image["bytes"] == image["bytesPerLine"] * image["height"]
                assert image["width"] <= 8192 and image["height"] <= 8192, image
                assert image["bytes"] <= 64 * 1024 * 1024, image

            def probe(image, x, y, expected):
                actual = image.pixelColor(round(x * dpr), round(y * dpr)).name()
                assert actual == expected, (x, y, actual, expected)

            if case in ("all", "allocation"):
                since = len(allocations)
                send(240, 50)
                image = capture("font48-grid240x50")
                check_image("font48-grid240x50", since)
                cw, ch = terminal.property("cellWidth"), terminal.property("cellHeight")
                inset = terminal.property("padding")
                assert viewport.property("contentWidth") == 240 * cw
                assert viewport.property("contentHeight") == 50 * ch
                # At the cap the coloured backgrounds still end at column 20,
                # rather than at a shrunken fraction of its declared position.
                probe(image, inset + 19.5 * cw, inset + ch / 2, "#cc241d")
                probe(image, inset + 20.5 * cw, inset + ch / 2, "#458588")
                viewport.setProperty("contentX", viewport.property("contentWidth") - viewport.property("width"))
                viewport.setProperty("contentY", viewport.property("contentHeight") - viewport.property("height"))
                image = capture("last-cell-scroll")
                probe(image, inset + viewport.property("width") - cw / 2,
                      inset + viewport.property("height") - ch / 2, "#458588")

                # A much wider grid must hit the side limit independently of
                # the area limit, while remaining a real, visible TerminalView.
                since = len(allocations)
                root.setProperty("size", 200)
                send(240, 2, 2)
                viewport.setProperty("contentX", 0)
                viewport.setProperty("contentY", 0)
                capture("side-limit")
                check_image("side-limit", since)
                assert allocations[-1]["width"] >= 8190, allocations[-1]

                since = len(allocations)
                send(24, 100, 3)
                capture("vertical-side-limit")
                check_image("vertical-side-limit", since)
                assert allocations[-1]["height"] >= 8190, allocations[-1]

                # These legal grids exceed 16 Mi pixels after QSize's DPR
                # rounding even though the unrounded area is within budget.
                for size, columns, rows in ((34, 115, 98), (28, 114, 100)):
                    since = len(allocations)
                    root.setProperty("size", size)
                    send(columns, rows, 3)
                    name = f"dpr-rounding-font{size}-grid{columns}x{rows}"
                    capture(name)
                    check_image(name, since)

                since = len(allocations)
                root.setProperty("size", 48)
                send(240, 50, 3)
                root.setProperty("full", True)
                root.setProperty("mode", "fit")
                image = capture("scroll-to-fit")
                check_image("scroll-to-fit", since)
                assert viewport.property("contentX") == viewport.property("contentY") == 0
                scale = terminal.property("fitScale")
                inset = terminal.property("padding")
                probe(image, inset + 239.5 * cw * scale, inset + 49.5 * ch * scale, "#458588")

            if case in ("all", "density"):
                root.setProperty("size", 14)
                root.setProperty("full", True)
                root.setProperty("mode", "resize")
                root.setProperty("density", 1)
                send(80, 24, 4)
                actions = []
                terminal.actionRequested.connect(lambda action, payload: actions.append((action, variant(payload))))
                capture("density1")
                columns = min(240, max(2, math.floor(viewport.property("width") / terminal.property("cellWidth"))))
                rows = min(100, 12000 // columns, max(1, math.floor(viewport.property("height") / terminal.property("cellHeight"))))
                assert actions[-1] == ("resize", dict(columns=columns, rows=rows)), actions
                original = dict(columns=columns, rows=rows)
                # Acknowledge the first resize, then change density alone.
                send(columns, rows, 5)
                flush()
                actions.clear()
                before = [terminal.property(key) for key in ("width", "height", "cellWidth", "cellHeight")]
                root.setProperty("density", 2)
                capture("density2")
                assert before == [terminal.property(key) for key in ("width", "height", "cellWidth", "cellHeight")]
                columns = min(240, max(2, math.floor(viewport.property("width") / terminal.property("cellWidth"))))
                rows = min(100, 12000 // columns, max(1, math.floor(viewport.property("height") / terminal.property("cellHeight"))))
                expected = dict(columns=columns, rows=rows)
                results.append(dict(case="density-only-resize", before=original, expected=expected, actions=actions.copy()))
                assert expected != original
                assert actions == [("resize", expected)], actions
                send(columns, rows, 6)
                flush()
                actions.clear()
                root.setProperty("density", 1)
                capture("density-restored")
                assert actions == [("resize", original)], actions
            assert not errors, errors
            assert all(image["width"] <= 8192 and image["height"] <= 8192
                       and image["bytes"] <= 64 * 1024 * 1024 for image in allocations), allocations
            report["passed"] = True
    finally:
        report["allocations"] = allocations
        (output / f"{prefix}.json").write_text(json.dumps(report, indent=2) + "\n")
        (output / f"{prefix}-native-image.log").write_text("\n".join(diagnostics) + "\n")
        try:
            canvas.diagnosticsChanged.disconnect(allocated)
        except (RuntimeError, UnboundLocalError):
            pass
        view.close()
        qInstallMessageHandler(previous_handler)
    print(json.dumps(dict(dpr=dpr, cases=len(results),
                          maximumPrimaryBytes=max(image["bytes"] for image in allocations), passed=True)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dpr", type=float, choices=DPRS)
    parser.add_argument("--case", choices=("all", "allocation", "density"), default="all")
    parser.add_argument("--output-directory", type=Path, default=Path("/tmp/blox-terminal-limits"))
    args = parser.parse_args()
    if args.dpr:
        run(args.dpr, args.output_directory, args.case)
    else:
        for dpr in DPRS:
            subprocess.run([sys.executable, __file__, "--dpr", str(dpr), "--case", args.case,
                            "--output-directory", str(args.output_directory)], check=True, timeout=30)
