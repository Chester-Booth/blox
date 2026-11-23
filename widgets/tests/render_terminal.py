"""Offscreen cell paint/erase and fullscreen geometry fixture.

Run with `python widgets/tests/render_terminal.py`. This checks correctness, not
live shell integration, frame freshness or a performance acceptance target.
"""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time

# A documented direct invocation must remain isolated even when launched from
# an existing graphical session with desktop-specific Qt and GTK settings.
_temporary_parent = Path(os.environ.get("BLOX_WIDGETS_TEST_TMPDIR", str(Path.home() / ".cache")))
_temporary_parent.mkdir(parents=True, exist_ok=True)
_PRIVATE_ENV = tempfile.TemporaryDirectory(prefix="blox-terminal-fixture-", dir=_temporary_parent)
_private_root = Path(_PRIVATE_ENV.name)
tempfile.tempdir = str(_private_root)
os.environ.update({
    "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software",
    "QT_QPA_PLATFORMTHEME": "generic", "QT_STYLE_OVERRIDE": "Fusion",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(_private_root / "no-session-bus"),
    "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=" + str(_private_root / "no-system-bus"),
    "HOME": str(_private_root), "XDG_CONFIG_HOME": str(_private_root),
    "XDG_DATA_HOME": str(_private_root), "XDG_CACHE_HOME": str(_private_root),
    "XDG_RUNTIME_DIR": str(_private_root),
})
for _name in ("DISPLAY", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "GTK_THEME",
              "QT_PLUGIN_PATH", "QT_QPA_PLATFORM_PLUGIN_PATH", "QML_IMPORT_PATH", "QML2_IMPORT_PATH"):
    os.environ.pop(_name, None)

from PySide6.QtCore import QObject, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQuick import QQuickView

WIDGETS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WIDGETS / "lib"))
from blox_widgets.terminal import AnsiScreen
from blox_widgets.broker import OutputQueue


def render(output_directory: Path | None = None):
    app = QGuiApplication.instance() or QGuiApplication([])
    with tempfile.TemporaryDirectory(prefix="blox-terminal-render-") as temporary:
        source = Path(temporary) / "TerminalFixture.qml"
        source.write_text('''import QtQuick
import "NATIVE_URL" as Native
import "FIXTURE_URL" as Fixtures
Rectangle {
    id: root
    width: 320; height: 100; color: "#112233"
    property var frame: ({})
    property var nativeFrame: ({})
    Fixtures.TerminalFixtureDecoder { id: decoder }
    onFrameChanged: if (frame.value) nativeFrame = decoder.adapt("fixture", frame)
    Native.TerminalView {
        objectName: "terminal"; anchors.fill: parent
        snapshot: root.nativeFrame
        settings: ({columns: 20, rows: 3})
    }
}
'''.replace("NATIVE_URL", (WIDGETS / "qml/Blox/Widgets/Native").as_uri())
            .replace("FIXTURE_URL", (WIDGETS / "tests/fixtures").as_uri()))
        view = QQuickView()
        view.engine().addImportPath(str(WIDGETS / "qml"))
        view.engine().addImportPath(os.environ.get("BLOX_WIDGETS_IMPORT_PATH", str(WIDGETS / "qml")))
        view.setSource(QUrl.fromLocalFile(str(source)))
        assert view.status() != QQuickView.Status.Error, view.errors()
        view.show()

        def flush():
            for _ in range(10):
                app.processEvents()
                time.sleep(.01)

        def frame(screen, sequence, dirty_rows=None, attempt=1):
            rows = [dict(runs=screen.runs(row)) for row in range(screen.rows)]
            dirty_rows = range(screen.rows) if dirty_rows is None else dirty_rows
            return dict(generation=1, revision=sequence, state="ready", value=dict(
                        generation=1, attempt=attempt, columns=screen.columns, rowCount=screen.rows,
                        rows=rows, changedRuns=[dict(row=row, **run) for row in dirty_rows
                                               for run in rows[row]["runs"]], sequence=sequence))

        screen = AnsiScreen(3, 20)
        screen.feed(b"\x1b[41m    \x1b[0mabc")
        root = view.rootObject()
        root.setProperty("frame", frame(screen, 1))
        flush()
        first = view.grabWindow()
        assert not first.isNull()
        terminal = root.findChild(QObject, "terminal")
        inset = int(terminal.property("padding"))
        assert first.pixelColor(inset + 2, inset + 2).name() == "#cc241d"
        assert terminal.property("contentReady")
        screen.feed(b"\r\x1b[2K")
        root.setProperty("frame", frame(screen, 2))
        flush()
        second = view.grabWindow()
        assert second.pixelColor(inset + 2, inset + 2).name() == "#112233"
        assert second.pixelColor(inset + 40, inset + 8).name() == "#112233"

        # Exercise real broker coalescing after a frame is already painted.
        # Frame 4 clears row 0 but is replaced before transport. Frame 5 only
        # lists row 1 as changed, so the renderer must recover row 0 from rows.
        screen.feed(b"\x1b[1;1H\x1b[41m    \x1b[2;1H\x1b[44m    \x1b[0m")
        root.setProperty("frame", frame(screen, 3))
        flush()
        assert view.grabWindow().pixelColor(inset + 2, inset + 2).name() == "#cc241d"
        output = OutputQueue()
        screen.feed(b"\x1b[1;1H\x1b[2K")
        output.emit(dict(consumerId="terminal", snapshot=frame(screen, 4, [0])))
        screen.feed(b"\x1b[2;1H\x1b[2K")
        output.emit(dict(consumerId="terminal", snapshot=frame(screen, 5, [1])))
        assert len(output.snapshots) == 1
        encoded = output.chunk()
        latest = json.loads(encoded)["snapshot"]
        output.advance(len(encoded))
        assert not output
        assert latest["value"]["sequence"] == 5
        assert all(run["row"] == 1 for run in latest["value"]["changedRuns"])
        root.setProperty("frame", latest)
        flush()
        recovered = view.grabWindow()
        assert recovered.pixelColor(inset + 2, inset + 2).name() == "#112233"
        assert recovered.pixelColor(inset + 2, inset + int(terminal.property("cellHeight")) + 2).name() == "#112233"

        # Queue updates without GUI events. Only the latest native frame and
        # the last prepared image may survive; no frame FIFO or JS cell state.
        canvas = next(item for item in root.findChildren(QObject)
                      if item.metaObject().indexOfProperty("diagnostics") >= 0)
        before = canvas.property("diagnostics")["completedFrames"]
        for sequence in range(6, 1006):
            root.setProperty("frame", frame(screen, sequence, [0]))
        assert canvas.property("diagnostics")["completedFrames"] == before
        assert canvas.property("diagnostics")["liveModels"] <= 4
        root.setProperty("frame", frame(screen, 1007, [1]))
        flush()
        assert canvas.property("diagnostics")["revision"] == 1007

        # A replacement attempt can have adjacent sequence/revision numbers
        # and identical dimensions. Attempt identity must still clear old rows.
        screen.feed(b"\x1b[1;1H\x1b[41m    \x1b[0m")
        root.setProperty("frame", frame(screen, 1008, [0]))
        flush()
        assert view.grabWindow().pixelColor(inset + 2, inset + 2).name() == "#cc241d"
        empty = AnsiScreen(3, 20)
        root.setProperty("frame", frame(empty, 1009, [], attempt=2))
        flush()
        assert view.grabWindow().pixelColor(inset + 2, inset + 2).name() == "#112233"

        actions = []
        terminal.actionRequested.connect(lambda action, payload: actions.append((action, payload)))
        terminal.setProperty("fullscreen", True)
        terminal.setProperty("context", {"fullscreenMode": "fit", "scrollbars": "show"})
        flush()
        assert terminal.property("scrollbarMode") == "hide"
        assert not actions
        terminal.setProperty("context", {"fullscreenMode": "resize", "scrollbars": "show"})
        flush()
        assert actions and actions[-1][0] == "resize"
        payload = actions[-1][1]
        payload = payload.toVariant() if hasattr(payload, "toVariant") else payload
        columns = min(240, max(2, math.floor((320 - 2 * terminal.property("padding")) / terminal.property("cellWidth"))))
        rows = min(100, 12000 // columns, max(1, math.floor((100 - 2 * terminal.property("padding")) / terminal.property("cellHeight"))))
        assert payload == {"columns": columns, "rows": rows}, payload
        terminal.setProperty("fullscreen", False)
        flush()
        restored = actions[-1][1]
        restored = restored.toVariant() if hasattr(restored, "toVariant") else restored
        assert restored == {"columns": 20, "rows": 3}, restored
        if output_directory:
            output_directory.mkdir(parents=True, exist_ok=True)
            first.save(str(output_directory / "terminal-coloured.png"))
            second.save(str(output_directory / "terminal-cleared.png"))
            recovered.save(str(output_directory / "terminal-coalesced-cleared.png"))
        view.close()
    print("TerminalView native paint, blank clearing, coalesced frame recovery, bounded models and fullscreen resize assertions passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-directory", type=Path)
    render(parser.parse_args().output_directory)
