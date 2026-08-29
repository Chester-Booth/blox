import qs.shared
import QtQuick
import Quickshell.Io

BloxButton {
    id: root

    property string value: ""
    property bool copied: false
    property bool failed: false

    compact: true
    enabled: value.length > 0 && !copyProcess.running
    iconName: copied ? "check-circle" : "copy"
    text: copied ? "Copied" : failed ? "Copy failed" : "Copy path"

    onClicked: {
        copied = false;
        failed = false;
        copyProcess.running = true;
    }

    Process {
        id: copyProcess

        command: ["wl-copy", root.value]
        onExited: (exitCode) => {
            root.copied = exitCode === 0;
            root.failed = exitCode !== 0;
            feedbackTimer.restart();
        }
    }

    Timer {
        id: feedbackTimer

        interval: 1800
        repeat: false
        onTriggered: {
            root.copied = false;
            root.failed = false;
        }
    }
}
