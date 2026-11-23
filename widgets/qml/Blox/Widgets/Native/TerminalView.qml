import QtQuick
import QtQuick.Controls
import Blox.Widgets.Terminal 1.0
import ".."

NativeView {
    id: root
    clip: true
    readonly property var frameData: snapshot && snapshot.value ? snapshot.value : ({})
    readonly property string lifecycle: snapshot && snapshot.state === "unavailable" ? "unavailable" : frameData.lifecycle || ""
    readonly property bool hasRecoveryStatus: ["draining", "retained-success", "retained-failure", "backoff", "runtime-limit", "unavailable"].indexOf(lifecycle) >= 0
    readonly property bool recoveryFailed: lifecycle === "retained-failure" || lifecycle === "unavailable"
    readonly property string recoveryStatus: {
        const exit = numeric(frameData.exitCode) ? "exit " + frameData.exitCode : "";
        if (lifecycle === "unavailable") return "Unavailable" + (snapshot && snapshot.error ? " · " + snapshot.error : "");
        if (lifecycle === "runtime-limit") return "Retained · runtime limit";
        const result = frameData.failure && frameData.failure.kind === "launch-failed" ? "launch failed" : exit;
        const status = (lifecycle === "draining" ? "Draining" : "Retained") + (result ? " · " + result : "");
        // Backoff is broker-owned. A fixed label needs no countdown timer.
        return hasRecoveryStatus ? status + (lifecycle === "backoff" && frameData.restartPending ? " · retry pending" : "") : "";
    }
    readonly property string fullscreenMode: context && context.fullscreenMode ? context.fullscreenMode : "fit"
    readonly property real textSize: (theme && theme.fontSize ? theme.fontSize : 14) * (compactPresentation ? 0.9 : 1)
    readonly property string requestedFamily: theme && theme.monospaceFamily ? theme.monospaceFamily : "monospace"
    // Resolve once, then use the same family for measurement and native glyphs.
    // A proportional theme fallback must not widen terminal cells.
    readonly property string textFamily: fixedCellFont ? requestedFont.family : fallbackFont.family
    readonly property bool fixedCellFont: {
        const font = requestedMetrics.font;
        const advance = requestedMetrics.advanceWidth("M");
        for (let code = 32; code < 127; ++code) {
            if (Math.abs(requestedMetrics.advanceWidth(String.fromCharCode(code)) - advance) > 1 / 64) return false;
        }
        return true;
    }
    readonly property color terminalBackground: theme && theme.palette ? theme.palette.background : "#161a20"
    readonly property real cellWidth: {
        // advanceWidth() has no notify signal; track font changes explicitly.
        const font = metrics.font;
        return Math.max(1, metrics.advanceWidth("M"));
    }
    readonly property real cellHeight: Math.max(1, Math.ceil(metrics.height))
    readonly property real fitScale: fullscreen && fullscreenMode === "fit" ? Math.min(viewport.width / Math.max(1, canvas.gridWidth), viewport.height / Math.max(1, canvas.gridHeight)) : 1
    property bool resizedForFullscreen: false
    property int requestedColumns: 0
    property int requestedRows: 0
    property int sizeGeneration: -1
    contentReady: !!snapshot && snapshot.state === "ready" && width > 0 && height > 0 && canvas.contentReady

    FontInfo { id: requestedFont; font.family: root.requestedFamily; font.pixelSize: root.textSize }
    FontMetrics { id: requestedMetrics; font: requestedFont.font }
    FontInfo { id: fallbackFont; font.family: "monospace"; font.pixelSize: root.textSize }
    FontMetrics {
        id: metrics
        font.family: root.textFamily
        font.pixelSize: root.textSize
    }
    function desiredTerminalSize() {
        if (width <= 0 || height <= 0) return null;
        if (fullscreen && fullscreenMode === "resize") {
            const columns = Math.min(240, Math.max(2, Math.floor(viewport.width / cellWidth)));
            const rows = Math.min(100, Math.floor(12000 / columns), Math.max(1, Math.floor(viewport.height / cellHeight)));
            return {columns: columns, rows: rows};
        }
        return resizedForFullscreen ? {columns: settings.columns || 80, rows: settings.rows || 24} : null;
    }
    readonly property bool canRestart: visible && width > 0 && height > 0 && hasRecoveryStatus
        && !!context && !context.editing && typeof context.requestRefresh === "function"

    function restartTerminal() {
        if (canRestart) context.requestRefresh();
    }
    function needsTerminalSize(size) {
        if (!size) return false;
        if (requestedColumns > 0)
            return size.columns !== requestedColumns || size.rows !== requestedRows;
        return size.columns !== frameData.columns || size.rows !== frameData.rowCount;
    }
    function queueTerminalSize() {
        if (fullscreen && fullscreenMode === "resize") resizedForFullscreen = true;
        const size = desiredTerminalSize();
        // Keep the first deadline. Continuous snapshots must not postpone resize.
        if (needsTerminalSize(size) && !resizeTimer.running) resizeTimer.start();
    }
    function requestTerminalSize() {
        const size = desiredTerminalSize();
        const resizing = fullscreen && fullscreenMode === "resize";
        if (needsTerminalSize(size)) {
            requestedColumns = size.columns;
            requestedRows = size.rows;
            actionRequested("resize", size);
        }
        resizedForFullscreen = resizing;
    }
    onFullscreenChanged: queueTerminalSize()
    onFullscreenModeChanged: queueTerminalSize()
    onCellWidthChanged: queueTerminalSize()
    onCellHeightChanged: queueTerminalSize()
    onFrameDataChanged: {
        if (frameData.generation !== undefined && frameData.generation !== sizeGeneration) {
            sizeGeneration = frameData.generation;
            requestedColumns = 0;
            requestedRows = 0;
        }
        queueTerminalSize();
    }
    onSettingsChanged: queueTerminalSize()
    Timer { id: resizeTimer; interval: 20; onTriggered: root.requestTerminalSize() }

    Flickable {
        id: viewport
        objectName: "terminalViewport"
        x: root.padding
        y: root.padding
        width: Math.max(0, root.width - 2 * root.padding)
        height: Math.max(0, root.height - 2 * root.padding - (root.hasRecoveryStatus ? 30 * root.density : 0))
        clip: true
        contentWidth: canvas.displayWidth
        contentHeight: canvas.displayHeight
        onWidthChanged: root.queueTerminalSize()
        onHeightChanged: root.queueTerminalSize()
        interactive: !root.fullscreen || root.fullscreenMode === "scroll"
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.horizontal: ScrollBar {
            policy: root.scrollbarMode === "hide" ? ScrollBar.AlwaysOff : root.scrollbarMode === "show" ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
            visible: !root.fullscreen && policy !== ScrollBar.AlwaysOff
        }
        ScrollBar.vertical: ScrollBar {
            policy: root.scrollbarMode === "hide" ? ScrollBar.AlwaysOff : root.scrollbarMode === "show" ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
            visible: !root.fullscreen && policy !== ScrollBar.AlwaysOff
        }
        TerminalSurface {
            id: canvas
            objectName: "terminalCanvas"
            frame: root.width > 0 && root.height > 0 ? root.frameData : ({})
            fontFamily: root.textFamily
            fontSize: metrics.font.pixelSize
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            ascent: metrics.ascent
            foreground: root.foreground
            background: root.terminalBackground
            drawScale: root.fitScale
        }
    }
    Item {
        id: recoveryRow
        objectName: "terminalRecoveryRow"
        visible: root.hasRecoveryStatus
        x: root.padding
        y: Math.max(0, root.height - height - root.padding / 2)
        width: Math.max(0, root.width - 2 * root.padding)
        height: Math.min(Math.max(restart.implicitHeight, status.implicitHeight), Math.max(0, root.height - root.padding / 2))
        clip: true
        Text {
            id: status
            objectName: "terminalRecoveryStatus"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - restart.width - 6 * root.density)
            height: Math.min(implicitHeight, parent.height)
            text: root.recoveryStatus
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.recoveryFailed ? root.colour("negative", "#ef8f91") : root.muted
            font.family: root.bodyFont
            font.pixelSize: 12
        }
        NativeAction {
            id: restart
            objectName: "terminalRestartAction"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(72 * root.density, parent.width)
            height: Math.min(implicitHeight, parent.height)
            text: "Restart"
            Accessible.name: "Restart terminal"
            enabled: root.canRestart
            foreground: root.accent
            accent: root.accent
            rounding: root.rounding
            density: root.density
            fontFamily: root.bodyFont
            pixelSize: 12
            onClicked: root.restartTerminal()
        }
    }
}
