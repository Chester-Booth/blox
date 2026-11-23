import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: root

    property string targetAddress: ""
    property int targetPid: 0
    property string targetClass: ""
    property bool pending: false
    property bool tracking: false
    property double deadline: 0
    readonly property bool restoringFocus: restoreFocus.running
    property bool focusRestoreSuccessful: false

    signal closeRequested()

    function normaliseAddress(value) {
        return String(value || "").toLowerCase().replace(/^0x/, "");
    }

    function captureTarget() {
        const state = Hyprland.activeToplevel ? Hyprland.activeToplevel.lastIpcObject || ({
        }) : ({
        });
        const address = normaliseAddress(state.address);
        const title = String(state.title || "");
        const windowClass = String(state.class || "");
        const isPicker = windowClass === "org.quickshell" && (title === "Blox Clipboard" || title === "Blox Emoji Picker");
        const pid = Number(state.pid || 0);
        const validTarget = /^[0-9a-f]+$/.test(address)
            && Number.isInteger(pid) && pid > 0 && windowClass.trim().length > 0;
        const currentTargetIsValid = /^[0-9a-f]+$/.test(targetAddress)
            && targetPid > 0 && targetClass.trim().length > 0;

        if (isPicker || !validTarget) {
            if (tracking && currentTargetIsValid)
                return;

            targetAddress = "";
            targetPid = 0;
            targetClass = "";
            return;
        }

        targetAddress = address;
        targetPid = pid;
        targetClass = windowClass;
    }

    // Explicit picker dismissal returns to its captured app. Outside clicks keep their own focus.
    function restoreTarget() {
        if (!targetAddress.length || targetPid <= 0 || !targetClass.length || restoreFocus.running) return false;
        restoreFocus.command = ["python3", Quickshell.shellDir + "/scripts/launcher/restore_focus.py", targetAddress, String(targetPid), targetClass];
        restoreFocus.running = true;
        return true;
    }

    function pasteWhenRestored() {
        pending = true;
        deadline = Date.now() + 300;
        closeRequested();
        if (!restoreTarget()) pollTimer.restart();
    }

    function finishWithoutPaste() {
        pending = false;
        Quickshell.execDetached(["notify-send", "--app-name", "Blox clipboard", "--expire-time", "2500", "Copied", "The previous window did not regain focus, so the value was left on the clipboard."]);
    }

    Timer {
        interval: 100
        repeat: true
        running: root.tracking && !root.pending
        triggeredOnStart: true
        onTriggered: root.captureTarget()
    }

    Timer {
        id: pollTimer

        interval: 25
        repeat: false
        onTriggered: {
            if (!root.pending)
                return ;

            if (!root.targetAddress.length) {
                root.finishWithoutPaste();
                return ;
            }
            activeWindow.running = true;
        }
    }

    Process {
        id: restoreFocus
        objectName: "picker-focus-restore"
        onStarted: root.focusRestoreSuccessful = false
        onExited: (exitCode, exitStatus) => {
            root.focusRestoreSuccessful = exitCode === 0 && exitStatus === 0;
            if (root.pending) {
                root.deadline = Date.now() + 300;
                pollTimer.restart();
            }
        }
    }

    Process {
        id: activeWindow
        objectName: "picker-active-window"

        command: ["hyprctl", "activewindow", "-j"]

        stdout: StdioCollector {
            onStreamFinished: {
                if (!root.pending)
                    return ;

                let address = "";
                try {
                    address = root.normaliseAddress(JSON.parse(text).address);
                } catch (error) {
                }
                if (address.length && address === root.targetAddress) {
                    root.pending = false;
                    paste.running = true;
                } else if (Date.now() < root.deadline) {
                    pollTimer.restart();
                } else {
                    root.finishWithoutPaste();
                }
            }
        }

    }

    Process {
        id: paste
        objectName: "picker-paste"

        command: ["wtype", "-M", "ctrl", "-k", "v", "-m", "ctrl"]
        onExited: (exitCode) => {
            if (exitCode !== 0)
                Quickshell.execDetached(["notify-send", "--app-name", "Blox clipboard", "--expire-time", "2500", "Copied", "Automatic paste failed, so the value was left on the clipboard."]);

        }
    }

}
