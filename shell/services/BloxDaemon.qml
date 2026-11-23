import QtQuick
import Quickshell
import Quickshell.Io

// Persistent single-process Rust daemon (bloxd bar-daemon) streaming typed
// workspace, system, and hardware status snapshots with zero idle forks.
Scope {
    id: root

    property bool enabled: true
    property int systemIntervalMs: 0
    readonly property string binaryPath: Quickshell.shellDir + "/native/qml/Blox/Services/bloxd"
    readonly property alias workspaces: workspacesChannel
    readonly property alias system: systemChannel
    readonly property alias caffeine: caffeineChannel

    signal monitorEvent(string eventName)

    component Channel: QtObject {
        property string domain: ""
        property var json: ({})
        property bool ok: true
        property real lastUpdatedMs: 0
        property bool timedOut: false
        property string lastError: ""
        property int interval: 0

        function refresh() {
            root.requestRefresh(domain);
        }
    }

    Channel { id: workspacesChannel; domain: "workspaces" }
    Channel { id: systemChannel; domain: "system" }
    Channel { id: caffeineChannel; domain: "caffeine" }

    function sendCommand(payload) {
        if (!daemon.running)
            return;
        daemon.write(JSON.stringify(payload) + "\n");
    }

    function requestRefresh(domain) {
        sendCommand({cmd: "refresh", domain: domain || "all"});
    }

    function setSystemInterval(ms) {
        const next = Math.max(0, Math.round(Number(ms || 0)));
        if (next === systemIntervalMs)
            return;
        systemIntervalMs = next;
        sendCommand({cmd: "set_system_interval", ms: next});
    }

    function applyMessage(line) {
        if (!line || !line.length)
            return;
        try {
            const msg = JSON.parse(line);
            const domain = String(msg.domain || "");
            const data = msg.data || ({});
            const now = Date.now();
            if (domain === "workspaces") {
                workspacesChannel.json = data;
                workspacesChannel.ok = true;
                workspacesChannel.lastUpdatedMs = now;
                workspacesChannel.lastError = "";
            } else if (domain === "system") {
                systemChannel.json = data;
                systemChannel.ok = true;
                systemChannel.lastUpdatedMs = now;
                systemChannel.lastError = "";
            } else if (domain === "caffeine") {
                caffeineChannel.json = data;
                caffeineChannel.ok = true;
                caffeineChannel.lastUpdatedMs = now;
                caffeineChannel.lastError = "";
            } else if (domain === "monitorEvent") {
                root.monitorEvent(String(data.event || ""));
            }
        } catch (error) {
        }
    }

    Process {
        id: daemon

        command: [root.binaryPath, "bar-daemon"]
        stdinEnabled: true
        running: root.enabled
        onStarted: {
            if (root.systemIntervalMs > 0)
                root.sendCommand({cmd: "set_system_interval", ms: root.systemIntervalMs});
        }
        onExited: {
            if (root.enabled)
                restartTimer.restart();
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root.applyMessage(line)
        }
    }

    Timer {
        id: restartTimer

        interval: 1000
        repeat: false
        onTriggered: {
            if (root.enabled)
                daemon.running = true;
        }
    }
}
