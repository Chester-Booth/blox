import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

// Single-process Rust Wayland clipboard watcher replacing 3x wl-paste and per-copy Python forks.
Scope {
    id: root

    readonly property string binaryPath: Quickshell.shellDir + "/native/qml/Blox/Services/bloxd"
    property bool storageHealthy: false
    property bool healthy: watcher.running && storageHealthy

    Process {
        id: watcher

        command: [root.binaryPath, "clipboard-watch"]
        stdinEnabled: true
        running: true
        onExited: {
            root.storageHealthy = false;
            restartTimer.restart();
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                try {
                    const msg = JSON.parse(line);
                    if (msg && msg.ok === true && msg.ready === true)
                        root.storageHealthy = true;
                } catch (error) {
                }
            }
        }
    }

    Timer {
        id: restartTimer

        interval: 2000
        onTriggered: watcher.running = true
    }
}
