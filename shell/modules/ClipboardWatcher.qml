import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    readonly property string ingest: Quickshell.shellDir + "/scripts/launcher/clipboard-watch-ingest"
    readonly property string command: Quickshell.shellDir + "/scripts/launcher/clipboardctl.py"
    property bool storageHealthy: false
    property bool healthy: textWatcher.running && imageWatcher.running && filesWatcher.running && storageHealthy

    function watcher(type) {
        return ["wl-paste", "--type", type, "--watch", ingest];
    }

    function probeHealth() {
        if (!healthProbe.running)
            healthProbe.running = true;
    }

    Component.onCompleted: probeHealth()

    Process {
        id: textWatcher

        command: root.watcher("text")
        environment: ({
            "BLOX_CLIPBOARD_MIME": "text/plain;charset=utf-8"
        })
        running: true
        onExited: textRestart.restart()
    }

    Process {
        id: healthProbe

        command: [root.command, "list", "--limit", "1"]
        onExited: exitCode => {
            if (exitCode !== 0)
                root.storageHealthy = false;
        }

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.storageHealthy = JSON.parse(text).ok === true;
                } catch (error) {
                    root.storageHealthy = false;
                }
            }
        }
    }

    Process {
        id: imageWatcher

        command: root.watcher("image")
        environment: ({
            "BLOX_CLIPBOARD_MIME": "image/png"
        })
        running: true
        onExited: imageRestart.restart()
    }

    Process {
        id: filesWatcher

        command: root.watcher("text/uri-list")
        environment: ({
            "BLOX_CLIPBOARD_MIME": "text/uri-list"
        })
        running: true
        onExited: filesRestart.restart()
    }

    Timer {
        id: textRestart
        interval: 2000
        onTriggered: {
            textWatcher.running = true;
            root.probeHealth();
        }
    }

    Timer {
        id: imageRestart
        interval: 2000
        onTriggered: {
            imageWatcher.running = true;
            root.probeHealth();
        }
    }

    Timer {
        id: filesRestart
        interval: 2000
        onTriggered: {
            filesWatcher.running = true;
            root.probeHealth();
        }
    }
}
