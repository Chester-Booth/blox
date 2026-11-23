import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io

Image {
    id: root
    property var candidate: null
    property var frame: null
    property string previewError: ""
    property string requestedTheme: ""
    property string processOutput: ""
    readonly property real deviceScale: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    readonly property real hotspotX: frame ? frame.hotspotX / deviceScale : 0
    readonly property real hotspotY: frame ? frame.hotspotY / deviceScale : 0
    readonly property string candidateKey: candidate ? JSON.stringify({
        cursor: candidate.cursor, shape: candidate.shape, colours: candidate.colours
    }) : ""

    source: frame ? frame.source : ""
    width: frame ? frame.width / deviceScale : 0
    height: frame ? frame.height / deviceScale : 0
    fillMode: Image.Pad
    smooth: false
    mipmap: false
    visible: status === Image.Ready

    onCandidateKeyChanged: updateTimer.restart()

    Timer {
        id: updateTimer
        interval: 80
        onTriggered: {
            if (root.candidate && !process.running) {
                root.requestedTheme = JSON.stringify(root.candidate);
                process.running = true;
            }
        }
    }
    Process {
        id: process
        command: ["python3", Quickshell.shellDir + "/scripts/cursor_preview.py", root.requestedTheme]
        stdout: StdioCollector { onStreamFinished: root.processOutput = this.text }
        onExited: (exitCode, exitStatus) => {
            try {
                const result = JSON.parse(root.processOutput);
                root.frame = result.ok ? result.data : null;
                root.previewError = result.ok ? "" : result.message;
            } catch (error) {
                root.frame = null;
                root.previewError = "Cursor preview is unavailable.";
            }
            if (root.candidate && JSON.stringify(root.candidate) !== root.requestedTheme)
                updateTimer.restart();
        }
    }
    Component.onCompleted: updateTimer.restart()
}
