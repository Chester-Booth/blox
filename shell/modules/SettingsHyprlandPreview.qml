import QtQuick
import Quickshell
import Quickshell.Io

// Owns the temporary Settings Hyprland preview transaction. The helper
// snapshots the compositor once, batches candidate values, and restores the
// snapshot before Settings closes or hands control to Apply.
Scope {
    id: root

    required property var host
    property string pendingOperation: ""
    property string pendingPayload: ""
    property string pendingReason: ""
    property string operation: ""
    property string payload: ""
    property string operationReason: ""
    property bool suspended: false
    property bool transactionActive: false
    property string lastError: ""

    signal operationFinished(string operation, bool successful, string reason)

    function startPending() {
        if (process.running || pendingOperation.length === 0)
            return;

        operation = pendingOperation;
        payload = pendingPayload;
        operationReason = pendingReason;
        pendingOperation = "";
        pendingPayload = "";
        pendingReason = "";
        lastError = "";
        process.running = true;
    }

    function preview(source) {
        if (!source || suspended)
            return;

        if (pendingOperation === "restore")
            return;

        if (source.targets && source.targets.hyprland === true) {
            pendingOperation = "apply";
            pendingPayload = JSON.stringify(source);
        } else if (transactionActive || process.running || pendingOperation === "apply") {
            restoreFor("target-disabled");
            return;
        } else {
            return;
        }
        startPending();
    }

    function recover() {
        if (process.running || pendingOperation.length > 0)
            return;

        pendingOperation = "recover";
        startPending();
    }

    function restoreFor(reason) {
        pendingReason = String(reason || "");
        // A cold closed window may not know about the retained preview journal.
        // Apply must still ask the helper to restore it before capturing state.
        if (!transactionActive && !process.running && pendingOperation !== "apply" && reason !== "settings-apply")
            return false;

        pendingOperation = "restore";
        pendingPayload = "";
        startPending();
        return true;
    }

    Process {
        id: process

        command: operation === "apply"
            ? ["python3", root.host.scriptRoot + "/theme/hyprland_preview.py", "apply", payload]
            : ["python3", root.host.scriptRoot + "/theme/hyprland_preview.py", operation]

        onExited: (exitCode, exitStatus) => {
            const completedOperation = operation;
            const completedReason = operationReason;
            const successful = exitCode === 0;
            if (completedOperation === "apply")
                root.transactionActive = successful;
            else if (completedOperation === "restore" && successful)
                root.transactionActive = false;

            if (!successful && root.lastError.length > 0)
                root.host.errorMessage = root.lastError.trim();
            root.operationFinished(completedOperation, successful, completedReason);
            root.startPending();
        }

        stderr: StdioCollector {
            onStreamFinished: root.lastError = this.text
        }
    }
}
