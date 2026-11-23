import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

// Read-only bridge to the validated theme composition ledger and manifest.
Scope {
    id: root

    property bool active: false
    property string status: "idle"
    property string errorMessage: ""
    property var provenance: ({})
    property string processOutput: ""
    readonly property string runtimePath: Quickshell.shellDir + "/scripts/settings_composition_runtime.py"

    function refresh() {
        if (process.running)
            return false;
        processOutput = "";
        errorMessage = "";
        status = "loading";
        process.running = true;
        return true;
    }

    function finish(exitCode, exitStatus) {
        let response = null;
        try {
            response = JSON.parse(processOutput.trim());
        } catch (error) {
            response = null;
        }
        if (exitCode !== 0 || exitStatus !== 0 || !response || response.version !== 1
                || response.ok !== true || !response.data || !Array.isArray(response.data.targets)) {
            provenance = {};
            errorMessage = response && response.message ? response.message : "Could not read generated file provenance.";
            status = "error";
            return;
        }
        provenance = response.data;
        status = "ready";
    }

    Process {
        id: process
        command: ["python3", root.runtimePath]
        onExited: (exitCode, exitStatus) => root.finish(exitCode, exitStatus)
        stdout: StdioCollector {
            onStreamFinished: root.processOutput = this.text
        }
    }

    Timer {
        interval: 3000
        repeat: true
        running: root.active
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()
}
