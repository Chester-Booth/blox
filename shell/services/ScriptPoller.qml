import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property var command: []
    property int interval: 5000
    property int timeout: 15000
    property string raw: ""
    property var json: ({
    })
    property bool ok: true
    property real lastUpdatedMs: 0
    property bool refreshPending: false
    property string pendingRaw: ""
    property int lastExitCode: 0
    property string lastError: ""
    property bool timedOut: false

    function refresh() {
        if (command.length === 0)
            return ;

        if (process.running) {
            refreshPending = true;
            return ;
        }
        refreshPending = false;
        pendingRaw = "";
        timedOut = false;
        process.running = true;
    }

    Process {
        id: process

        command: root.command
        onStarted: watchdog.restart()
        onExited: (exitCode, exitStatus) => {
            watchdog.stop();
            forceKill.stop();
            root.lastExitCode = exitCode;
            if (root.timedOut) {
                root.lastError = "command timed out after " + root.timeout + " ms";
                root.ok = false;
            } else if (exitCode === 0 && exitStatus === 0) {
                const output = root.pendingRaw.trim();
                try {
                    const parsed = output.length > 0 ? JSON.parse(output) : {
                    };
                    root.raw = output;
                    root.json = parsed;
                    root.lastUpdatedMs = Date.now();
                    root.lastError = "";
                    root.ok = true;
                } catch (error) {
                    root.raw = output;
                    root.lastError = String(error);
                    root.ok = false;
                }
            } else {
                root.lastError = "command exited " + exitCode;
                root.ok = false;
            }
            if (root.refreshPending)
                Qt.callLater(root.refresh);

        }

        stdout: StdioCollector {
            onStreamFinished: {
                root.pendingRaw = this.text;
            }
        }

    }

    Timer {
        id: watchdog

        interval: Math.max(1, root.timeout)
        repeat: false
        onTriggered: {
            if (!process.running)
                return ;

            root.timedOut = true;
            process.signal(15);
            forceKill.restart();
        }
    }

    Timer {
        id: forceKill

        interval: 1000
        repeat: false
        onTriggered: {
            if (process.running)
                process.signal(9);

        }
    }

    Timer {
        interval: root.interval
        running: root.command.length > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

}
