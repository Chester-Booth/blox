import "../services"
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

Rectangle {
    id: root

    required property var widget
    property string scriptRoot: Quickshell.shellDir + "/scripts"
    property bool interactive: true
    property bool renderUpdates: true
    property int overrideWidth: 0
    property int overrideHeight: 0
    property int maximumWidth: 0
    property int maximumHeight: 0
    property string terminalFrame: ""
    property string clockFrame: ""
    readonly property bool terminalPreset: ["music", "clock", "aquarium", "pipes", "tree", "matrix", "train"].indexOf(widget.type) >= 0
    readonly property bool streamedTerminalPreset: terminalPreset
    readonly property bool persistentTerminalPreset: ["music", "clock", "aquarium", "pipes", "matrix"].indexOf(widget.type) >= 0
    readonly property int terminalFrameMilliseconds: widget.type === "music" ? 16 : widget.type === "aquarium" || widget.type === "clock" ? 500 : 250
    readonly property bool autoSize: widget.options && widget.options.auto_size === true
    readonly property real widgetScale: Math.max(0.25, Math.min(4, Number(widget.options && widget.options.scale || 1)))
    readonly property real configuredBackgroundOpacity: widget.options && widget.options.background_opacity !== undefined ? Number(widget.options.background_opacity) : Theme.widgetOpacity
    readonly property real backgroundOpacity: isNaN(configuredBackgroundOpacity) ? Theme.widgetOpacity : Math.max(0, Math.min(1, configuredBackgroundOpacity))
    readonly property real scaledPadding: Theme.widgetPadding * widgetScale
    readonly property int configuredWidth: autoSize ? 0 : Number(widget.width || 0)
    readonly property int configuredHeight: autoSize ? 0 : Number(widget.height || 0)
    readonly property int clockColumns: {
        let maximum = 0;
        const lines = clockFrame.split("\n");
        for (let index = 0; index < lines.length; index++) maximum = Math.max(maximum, lines[index].length)
        return maximum;
    }
    readonly property int clockRows: clockFrame.length > 0 ? clockFrame.split("\n").length : 1
    readonly property int clockCellWidth: Math.ceil(clockMetrics.averageCharacterWidth)
    readonly property int clockLineHeight: Math.ceil(clockMetrics.height)
    readonly property int clockContentWidth: clockColumns * clockCellWidth
    readonly property int clockContentHeight: clockRows * clockLineHeight
    readonly property int scrollbarThreshold: 8
    readonly property int requestedWidth: overrideWidth > 0 ? overrideWidth : configuredWidth > 0 ? configuredWidth * widgetScale : (widget.type === "clock" ? clockContentWidth : content.implicitWidth) + scaledPadding * 2
    readonly property int requestedHeight: overrideHeight > 0 ? overrideHeight : configuredHeight > 0 ? configuredHeight * widgetScale : (widget.type === "clock" ? clockContentHeight : content.implicitHeight) + scaledPadding * 2

    signal leftClicked()
    signal rightClicked()

    function expandedCommand(command) {
        return String(command || "").replace(/\$SCRIPT_ROOT/g, root.scriptRoot);
    }

    function contentCommand() {
        if (!root.terminalPreset)
            return ["sh", "-c", root.expandedCommand(root.widget.content_command)];

        const logicalWidth = root.overrideWidth > 0 ? root.overrideWidth / root.widgetScale : root.configuredWidth;
        const logicalHeight = root.overrideHeight > 0 ? root.overrideHeight / root.widgetScale : root.configuredHeight;
        const columns = logicalWidth > 0 ? Math.max(10, Math.floor(logicalWidth / Math.max(6, Theme.widgetFontSize * 0.6))) : 60;
        const rows = logicalHeight > 0 ? Math.max(4, Math.floor(logicalHeight / Math.max(10, Theme.widgetFontSize * 1.25))) : 20;
        const command = [root.scriptRoot + "/widgets/terminal-frame.py", root.widget.type, "--command", root.expandedCommand(root.widget.content_command), "--columns", String(columns), "--rows", String(rows)];
        if (root.streamedTerminalPreset)
            command.splice(2, 0, "--stream", "--frame-ms", String(root.terminalFrameMilliseconds));
        else
            command.splice(2, 0, "--duration-ms", "300");
        if (root.widget.type === "music")
            command.push("--plain");

        return command;
    }

    function refresh() {
        if (root.streamedTerminalPreset) {
            if (terminalProcess.running)
                terminalProcess.signal(15);
            else
                terminalProcess.running = true;
        } else {
            contentPoller.refresh();
        }
    }

    width: maximumWidth > 0 ? Math.min(requestedWidth, maximumWidth) : requestedWidth
    height: maximumHeight > 0 ? Math.min(requestedHeight, maximumHeight) : requestedHeight
    // The terminal renderer maps ANSI black to the theme's terminal canvas.
    // Use that same colour behind asciiquarium so its unpainted cells and the
    // surrounding widget do not form two visibly different backgrounds, in
    // every theme rather than one.
    color: widget.type === "clock" ? "transparent" : Theme.withAlpha(widget.type === "aquarium" ? Theme.terminalCanvas : Theme.background, backgroundOpacity)
    radius: widget.shape === "circle" ? Math.min(width, height) / 2 : widget.shape === "rounded" ? Math.max(10, Theme.widgetRadius) : widget.shape === "rectangle" ? 0 : Theme.widgetRadius

    ScriptPoller {
        id: contentPoller

        command: root.streamedTerminalPreset ? [] : root.contentCommand()
        interval: root.widget.type === "clock" ? 1000 : Math.max(250, Number(root.widget.interval_ms || 60000))
    }

    Connections {
        function onRawChanged() {
            if (root.widget.type !== "clock" || contentPoller.raw.length === 0)
                return ;

            root.clockFrame = contentPoller.raw;
        }

        target: contentPoller
    }

    Process {
        // Ignore incomplete output; the next complete frame replaces it.

        id: terminalProcess

        command: root.contentCommand()
        running: root.streamedTerminalPreset
        onExited: {
            if (root.persistentTerminalPreset)
                terminalRestart.restart();

        }
        Component.onDestruction: {
            terminalRestart.stop();
            if (running)
                signal(15);

        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: (data) => {
                if (!root.renderUpdates)
                    return ;

                try {
                    const frame = JSON.parse(data);
                    if (root.widget.type === "clock")
                        root.clockFrame = frame;
                    else
                        root.terminalFrame = frame;
                } catch (error) {
                }
            }
        }

    }

    Timer {
        id: terminalRestart

        interval: 500
        repeat: false
        onTriggered: {
            if (root.persistentTerminalPreset && !terminalProcess.running)
                terminalProcess.running = true;

        }
    }

    Flickable {
        id: contentViewport

        z: 1
        anchors.fill: parent
        anchors.margins: root.scaledPadding
        contentWidth: content.implicitWidth
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        visible: root.widget.type !== "clock"

        Text {
            id: content

            text: root.widget.type === "clock" ? (root.clockFrame.length > 0 ? root.clockFrame : "Loading…") : root.terminalPreset ? (root.terminalFrame.length > 0 ? root.terminalFrame : "Loading…") : (contentPoller.raw.length > 0 ? contentPoller.raw : "Loading…")
            textFormat: root.terminalPreset && root.widget.type !== "clock" && root.widget.type !== "music" ? Text.RichText : Text.PlainText
            color: Theme.foreground
            font.family: root.terminalPreset ? Theme.monoFontFamily : Theme.bodyFontFamily
            font.pixelSize: root.terminalPreset ? Math.max(1, Math.round(Theme.widgetFontSize * root.widgetScale)) : Theme.widgetFontSize * root.widgetScale
            lineHeightMode: root.widget.type === "music" ? Text.FixedHeight : Text.ProportionalHeight
            lineHeight: root.widget.type === "music" ? font.pixelSize : 1
            wrapMode: Text.NoWrap
            horizontalAlignment: Text.AlignLeft
            verticalAlignment: Text.AlignTop
        }

        ScrollBar.vertical: ScrollBar {
            id: verticalScrollbar

            parent: root
            z: 3
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.topMargin: root.scaledPadding
            anchors.rightMargin: Math.max(0, (root.scaledPadding - width) / 2)
            anchors.bottomMargin: Math.max(0, (root.scaledPadding - height) / 2)
            width: 8
            opacity: widgetHover.hovered ? 1 : 0
            policy: contentViewport.contentHeight > contentViewport.height + root.scrollbarThreshold ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

            Behavior on opacity {
                NumberAnimation {
                    duration: 110
                    easing.type: Easing.OutCubic
                }

            }

            background: Rectangle {
                radius: 999
                color: Theme.withAlpha(Theme.foreground, 0.04)
            }

            contentItem: Rectangle {
                implicitWidth: 4
                radius: 999
                color: verticalScrollbar.hovered || verticalScrollbar.pressed ? Theme.foreground : Theme.surfaceAlt
            }

        }

        ScrollBar.horizontal: ScrollBar {
            id: horizontalScrollbar

            parent: root
            z: 3
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: root.scaledPadding
            anchors.rightMargin: root.scaledPadding
            anchors.bottomMargin: root.scaledPadding
            height: 8
            opacity: widgetHover.hovered ? 1 : 0
            policy: contentViewport.contentWidth > contentViewport.width + root.scrollbarThreshold ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

            Behavior on opacity {
                NumberAnimation {
                    duration: 110
                    easing.type: Easing.OutCubic
                }

            }

            background: Rectangle {
                radius: 999
                color: Theme.withAlpha(Theme.foreground, 0.04)
            }

            contentItem: Rectangle {
                implicitHeight: 4
                radius: 999
                color: horizontalScrollbar.hovered || horizontalScrollbar.pressed ? Theme.foreground : Theme.surfaceAlt
            }

        }

    }

    FontMetrics {
        id: clockMetrics

        font.family: Theme.monoFontFamily
        font.pixelSize: Theme.widgetFontSize * root.widgetScale
    }

    Canvas {
        id: clockCanvas

        anchors.fill: parent
        visible: root.widget.type === "clock"
        renderTarget: Canvas.Image
        onPaint: {
            const context = getContext("2d");
            context.clearRect(0, 0, width, height);
            context.fillStyle = Theme.withAlpha(Theme.background, root.backgroundOpacity);
            context.fillRect(0, 0, width, height);
            context.fillStyle = Theme.foreground;
            context.font = clockMetrics.font.pixelSize + "px " + clockMetrics.font.family;
            context.textBaseline = "alphabetic";
            const lines = root.clockFrame.split("\n");
            for (let row = 0; row < lines.length; row++) {
                for (let column = 0; column < lines[row].length; column++) {
                    const character = lines[row][column];
                    if (character === "█")
                        context.fillRect(root.scaledPadding + column * root.clockCellWidth, root.scaledPadding + row * root.clockLineHeight, root.clockCellWidth, root.clockLineHeight);
                    else if (character !== " ")
                        context.fillText(character, root.scaledPadding + column * root.clockCellWidth, root.scaledPadding + row * root.clockLineHeight + clockMetrics.ascent);
                }
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        Connections {
            function onClockFrameChanged() {
                clockCanvas.requestPaint();
            }

            function onWidgetScaleChanged() {
                clockCanvas.requestPaint();
            }

            function onBackgroundOpacityChanged() {
                clockCanvas.requestPaint();
            }

            target: root
        }

    }

    MouseArea {
        z: 2
        anchors.fill: parent
        enabled: root.interactive
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (event) => {
            if (event.button === Qt.RightButton)
                root.rightClicked();
            else
                root.leftClicked();
        }
        onWheel: (event) => {
            const pixelDelta = event.pixelDelta.y || event.pixelDelta.x || 0;
            const angleDelta = event.angleDelta.y || event.angleDelta.x || 0;
            const delta = pixelDelta !== 0 ? pixelDelta : angleDelta / 2;
            if (contentViewport.contentHeight > contentViewport.height + root.scrollbarThreshold) {
                const maximumContentY = Math.max(contentViewport.originY, contentViewport.originY + contentViewport.contentHeight - contentViewport.height);
                contentViewport.contentY = Math.max(contentViewport.originY, Math.min(maximumContentY, contentViewport.contentY - delta * 4));
            } else if (contentViewport.contentWidth > contentViewport.width + root.scrollbarThreshold) {
                const maximumContentX = Math.max(contentViewport.originX, contentViewport.originX + contentViewport.contentWidth - contentViewport.width);
                contentViewport.contentX = Math.max(contentViewport.originX, Math.min(maximumContentX, contentViewport.contentX - delta * 4));
            }
            event.accepted = true;
        }
    }

    HoverHandler {
        id: widgetHover

        enabled: root.interactive
        cursorShape: Qt.PointingHandCursor
    }

}
