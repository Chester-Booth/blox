import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io
import "ActionContract.js" as ActionContract

// One loaded owner serialises all night-light mode writes.
Scope {
    id: root
    property string scriptRoot: ""
    property int revision: 0
    property string mode: "auto"
    property bool active: false
    property bool available: false
    property var startupResult: null
    property bool startupReconciled: false
    property bool observed: false
    property real observedAtMs: 0
    property string lastError: ""
    readonly property var json: ({mode: mode, active: active, providerRevision: revision,
        schemaVersion: 1, observedAtMs: observedAtMs, stale: !observed,
        busy: writer.running || probe.running, errorCode: lastError,
        capability: {available: available, ready: observed, canChange: available,
                     permission: "unknown", reason: available ? "" : "command-unavailable"}})

    function refresh() {
        if (scriptRoot && !probe.running && !writer.running) probe.running = true;
    }
    function acceptState(state) {
        mode = state.mode; active = state.active === true;
        available = state.available === true;
        observed = true; observedAtMs = Date.now(); revision++;
    }
    function reconcileSavedMode() {
        if (startupReconciled || !observed || !available) return false;
        startupResult = action("restore", mode);
        startupReconciled = true;
        return startupResult.ok;
    }
    function action(operation, value) {
        if (["set", "toggle", "restore"].indexOf(operation) < 0)
            return ActionContract.result(false, "invalid-data", "unknown night-light operation");
        // The old login hook may arrive after loaded startup reconciliation.
        // A second restore acknowledges that receipt without restarting the filter.
        if (operation === "restore" && startupReconciled)
            return startupResult || ActionContract.result(false, "busy", "Startup reconciliation has not completed");
        const blocked = ActionContract.blockedCode(json, available);
        if (blocked) return ActionContract.result(false, blocked, "night-light is unavailable");
        const selected = operation === "toggle" ? (active ? "off" : "on") : operation === "restore" ? mode : String(value);
        if (["on", "off", "auto"].indexOf(selected) < 0)
            return ActionContract.result(false, "invalid-data", "night-light mode must be on, off or auto");
        writer.command = ["timeout", "--signal=TERM", "--kill-after=1", "8", scriptRoot + "/providers/night-light.sh", selected].concat(operation === "restore" ? ["--quiet"] : []);
        writer.running = true;
        return ActionContract.accepted(operation, selected, json, revision);
    }
    Process {
        id: probe
        objectName: "nightLightProbe"
        command: ["timeout", "--signal=TERM", "--kill-after=1", "3", root.scriptRoot + "/providers/night-light.sh", "status"]
        onExited: (code, status) => {
            if (code !== 0) { root.observed = false; root.lastError = "failed"; }
            else Qt.callLater(root.reconcileSavedMode);
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const state = JSON.parse(text);
                    root.acceptState(state);
                } catch (error) { root.observed = false; root.lastError = "invalid-data"; }
            }
        }
    }
    Process {
        id: writer
        objectName: "nightLightWriter"
        onExited: (code, status) => {
            root.lastError = code === 0 ? "" : "failed";
            root.refresh();
        }
    }
    Timer { interval: 300000; repeat: true; running: root.mode === "auto" && root.scriptRoot.length > 0; onTriggered: root.refresh() }
    onScriptRootChanged: refresh()
    Component.onCompleted: refresh()
}
