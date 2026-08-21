import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: root

    property string targetAddress: ""
    property bool pending: false
    property bool tracking: false
    property double deadline: 0

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
        if (address.length && !isPicker)
            targetAddress = address;

    }

    function pasteWhenRestored() {
        pending = true;
        deadline = Date.now() + 300;
        closeRequested();
        pollTimer.restart();
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
        id: activeWindow

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

        command: ["wtype", "-M", "ctrl", "-k", "v", "-m", "ctrl"]
        onExited: (exitCode) => {
            if (exitCode !== 0)
                Quickshell.execDetached(["notify-send", "--app-name", "Blox clipboard", "--expire-time", "2500", "Copied", "Automatic paste failed, so the value was left on the clipboard."]);

        }
    }

}
