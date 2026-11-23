import QtQuick
import Quickshell
import Quickshell.Io

// The shell owns one Settings transaction endpoint. The Python runtime owns
// transaction rules; this controller serialises requests and returns typed results.
Scope {
    id: root

    signal widgetsPublished()

    property bool busy: false
    property int requestSerial: 0
    property string activeRequestId: ""
    property string activeOperation: ""
    property string processOutput: ""
    property string processError: ""
    property var completedResult: null
    readonly property string runtimePath: Quickshell.shellDir + "/scripts/settings_runtime.py"
    readonly property string recoveryPath: Quickshell.shellDir + "/scripts/hyprland_settings.py"
    property bool enableColdRecovery: true
    readonly property bool recovering: recoveryProcess.running || applyRecoveryProcess.running
    readonly property int schemaVersion: transactionState.schemaVersion
    readonly property int revision: transactionState.revision
    readonly property real observedAt: transactionState.observedAt
    readonly property bool dirty: transactionState.dirty
    readonly property bool conflict: transactionState.conflict
    readonly property var changedComponents: transactionState.changedComponents
    readonly property string commitState: transactionState.commitState
    readonly property string rollbackState: transactionState.rollbackState
    readonly property var error: transactionState.error
    readonly property var typedResult: transactionState.lastResult
    readonly property var settings: transactionState.settings

    function result(ok, code, message, data) {
        return {"version": 1, "ok": ok, "code": code, "message": message, "data": data};
    }

    function currentData(code, message) {
        const now = Date.now() / 1000;
        return {
            "schemaVersion": root.schemaVersion,
            "revision": root.revision,
            "beforeRevision": root.revision,
            "afterRevision": root.revision,
            "observedAt": now,
            "dirty": root.dirty,
            "conflict": code === "conflict",
            "changedComponents": [],
            "commitState": "not-committed",
            "rollbackState": "not-attempted",
            "error": {"code": code, "message": message},
            "settings": null
        };
    }

    function begin(operation, requestJson) {
        if (root.recovering)
            return JSON.stringify(root.result(false, "busy", "Settings recovery is running", root.currentData("busy", "Settings recovery is running")));
        if (root.busy)
            return JSON.stringify(root.result(false, "busy", "a Settings transaction is already running", root.currentData("busy", "a Settings transaction is already running")));

        root.activeOperation = operation;
        root.requestSerial += 1;
        root.activeRequestId = String(Date.now()) + "-" + String(root.requestSerial);
        root.completedResult = null;
        root.processOutput = "";
        root.processError = "";
        root.busy = true;
        runtimeProcess.command = ["python3", root.runtimePath, String(operation), String(requestJson)];
        runtimeProcess.running = true;
        return JSON.stringify(root.result(true, "pending", "", {"requestId": root.activeRequestId}));
    }

    function poll(requestId) {
        if (requestId !== root.activeRequestId)
            return JSON.stringify(root.result(false, "invalid-data", "unknown Settings request", root.currentData("invalid-data", "unknown Settings request")));
        if (root.busy)
            return JSON.stringify(root.result(true, "pending", "", {"requestId": root.activeRequestId}));
        if (root.completedResult !== null)
            return JSON.stringify(root.completedResult);
        return JSON.stringify(root.result(false, "unavailable", "the Settings owner has no result for this request", root.currentData("unavailable", "the Settings owner has no result for this request")));
    }

    function finish(action) {
        const publicationOnly = root.activeOperation === "apply-widgets";
        const accepted = publicationOnly ? transactionState.validResult(action) : transactionState.acceptResult(action);
        if (!accepted) {
            action = root.result(false, "invalid-data", "the Settings runtime returned an invalid result", root.currentData("invalid-data", "the Settings runtime returned an invalid result"));
            if (!publicationOnly) transactionState.acceptResult(action);
        }
        // A generation switch replaces a symlink, which need not notify the
        // FileView watching its previous target. Reload through the shell owner.
        if (publicationOnly && accepted && action.ok)
            root.widgetsPublished();
        root.completedResult = action;
        root.busy = false;
    }

    function processFinished(exitCode, exitStatus) {
        if (!root.busy)
            return;
        let action = null;
        try {
            action = JSON.parse(root.processOutput);
        } catch (error) {
            action = null;
        }
        if (exitCode !== 0 || exitStatus !== 0 || !transactionState.validResult(action)) {
            const message = root.processError || "the Settings runtime failed to return a valid result";
            root.finish(root.result(false, "internal", message, root.currentData("internal", message)));
            return;
        }
        root.finish(action);
    }

    SettingsState {
        id: transactionState
    }

    IpcHandler {
        function begin(operation: string, requestJson: string) : string {
            return root.begin(operation, requestJson);
        }

        function poll(requestId: string) : string {
            return root.poll(requestId);
        }

        target: "settings"
    }

    Process {
        id: runtimeProcess

        onExited: (exitCode, exitStatus) => root.processFinished(exitCode, exitStatus)
        stdout: StdioCollector {
            onStreamFinished: root.processOutput = this.text
        }
        stderr: StdioCollector {
            onStreamFinished: root.processError = this.text
        }
    }

    Process {
        id: recoveryProcess
        command: ["python3", root.recoveryPath, "recover"]
        Component.onCompleted: {
            if (root.enableColdRecovery)
                running = true;
        }
        onExited: (exitCode, exitStatus) => {
            running = false;
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("Hyprland Settings cold-start recovery failed");
                return;
            }
            applyRecoveryProcess.running = true;
        }
    }

    Process {
        id: applyRecoveryProcess
        command: ["python3", Quickshell.shellDir + "/scripts/apply_runtime.py", "recover"]
        onExited: (exitCode, exitStatus) => {
            running = false;
            if (exitCode === 0 && exitStatus === 0)
                Qt.callLater(root.begin, "get", "{}");
            else
                console.warn("Theme Apply cold-start recovery failed");
        }
    }

}
