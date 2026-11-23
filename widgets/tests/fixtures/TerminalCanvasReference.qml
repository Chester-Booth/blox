import QtQuick

// Test-only reference for the removed Canvas cell painter. Always paints a
// complete retained grid so visual comparisons do not depend on delta history.
Canvas {
    id: root
    property var frame: ({})
    property string fontFamily: "monospace"
    property real fontSize: 14
    property real cellWidth: 9
    property real cellHeight: 18
    property real ascent: 14
    property color foreground: "#e8edf4"
    property color background: "#161a20"
    property real drawScale: 1
    property int paints: 0
    readonly property real gridWidth: (frame.columns || 0) * cellWidth
    readonly property real gridHeight: (frame.rowCount || 0) * cellHeight
    readonly property real displayWidth: gridWidth * drawScale
    readonly property real displayHeight: gridHeight * drawScale
    readonly property real pixelRatio: Math.max(1, root.Window.window ? root.Window.window.devicePixelRatio : Screen.devicePixelRatio)
    readonly property real rasterScale: Math.max(0, Math.min(drawScale,
        8192 / Math.max(1, gridWidth * pixelRatio), 8192 / Math.max(1, gridHeight * pixelRatio),
        Math.sqrt(16777216 / Math.max(1, gridWidth * gridHeight * pixelRatio * pixelRatio))))
    readonly property size rasterSize: {
        let w = Math.max(1, Math.floor(gridWidth * rasterScale));
        let h = Math.max(1, Math.floor(gridHeight * rasterScale));
        if (Math.round(w * pixelRatio) * Math.round(h * pixelRatio) > 16777216) {
            if (w < h) --w; else --h;
        }
        return Qt.size(w, h);
    }
    width: rasterSize.width
    height: rasterSize.height
    transform: Scale { xScale: root.displayWidth / root.width; yScale: root.displayHeight / root.height }
    renderStrategy: Canvas.Immediate
    antialiasing: true
    function schedule() { if (available && visible) requestPaint(); }
    onFrameChanged: schedule()
    onAvailableChanged: schedule()
    onVisibleChanged: schedule()
    onWidthChanged: schedule()
    onHeightChanged: schedule()
    onFontFamilyChanged: schedule()
    onFontSizeChanged: schedule()
    onCellWidthChanged: schedule()
    onCellHeightChanged: schedule()
    onAscentChanged: schedule()
    onForegroundChanged: schedule()
    onBackgroundChanged: schedule()
    onPaint: {
        if (!visible || gridWidth <= 0 || gridHeight <= 0) return;
        const ctx = getContext("2d");
        ctx.resetTransform();
        const sx = canvasSize.width / gridWidth, sy = canvasSize.height / gridHeight;
        const clearWidth = Math.ceil(canvasSize.width * pixelRatio) / pixelRatio;
        ctx.clearRect(0, 0, clearWidth, Math.ceil(canvasSize.height * pixelRatio) / pixelRatio);
        ctx.textBaseline = "alphabetic";
        const rows = frame.rows || [];
        for (let row = 0; row < rows.length; ++row) {
            const y = row * cellHeight;
            const top = Math.round(y * sy * pixelRatio) / pixelRatio;
            const bottom = Math.round((y + cellHeight) * sy * pixelRatio) / pixelRatio;
            ctx.resetTransform();
            ctx.save(); ctx.setTransform(sx, 0, 0, sy, 0, 0);
            ctx.beginPath(); ctx.rect(0, top / sy, gridWidth, (bottom - top) / sy); ctx.clip();
            const runs = rows[row].runs || [];
            for (let n = 0; n < runs.length; ++n) {
                const run = runs[n], cells = run.cells || [];
                let fg = run.foreground || String(foreground), bg = run.background;
                if (run.inverse) { bg = fg; fg = run.background || String(background); }
                const x = run.column * cellWidth;
                if (bg) { ctx.fillStyle = bg; ctx.fillRect(x, top / sy, cells.length * cellWidth, (bottom - top) / sy); }
                ctx.fillStyle = fg;
                ctx.font = (run.bold ? "bold " : "") + fontSize + "px " + JSON.stringify(fontFamily);
                for (let col = 0; col < cells.length; ++col) {
                    if (!cells[col] || cells[col] === " ") continue;
                    const span = col + 1 < cells.length && cells[col + 1] === "" ? 2 : 1;
                    ctx.save(); ctx.beginPath();
                    ctx.rect(x + col * cellWidth, top / sy, span * cellWidth, (bottom - top) / sy); ctx.clip();
                    ctx.fillText(cells[col], x + col * cellWidth, y + ascent); ctx.restore();
                }
                if (run.underline) ctx.fillRect(x, y + ascent + 1, cells.length * cellWidth, 1);
            }
            ctx.restore();
        }
        paints++;
    }
}
