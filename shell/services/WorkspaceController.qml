import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: root

    property string scriptRoot: ""
    property var items: []
    property var special: ({
    })
    property string alertWorkspaceIds: ","
    property string alertWindowAddress: ""
    property string pendingLookupAddress: ""
    property bool blinkOn: true

    signal statusRefreshRequested()
    signal privacyRefreshRequested()
    signal focusedMonitorChanged()

    function activeWorkspaceId() {
        for (let i = 0; i < items.length; i++) {
            if (items[i].active)
                return items[i].id;

        }
        return -1;
    }

    function focusedWorkspaceId() {
        return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : activeWorkspaceId();
    }

    function hasAlert(id) {
        return alertWorkspaceIds.indexOf("," + id + ",") >= 0;
    }

    function addAlert(id, address) {
        if (id <= 0)
            return ;

        if (!hasAlert(id))
            alertWorkspaceIds += id + ",";

        if (address !== undefined && address.length > 0)
            alertWindowAddress = address;

        urgentSwitchDelay.restart();
    }

    function clearAlert(id) {
        alertWorkspaceIds = alertWorkspaceIds.replace("," + id + ",", ",");
    }

    function dispatch(expression) {
        Quickshell.execDetached(["hyprctl", "dispatch", expression]);
    }

    function focusWindow(address) {
        const value = String(address || "");
        if (!/^0x[0-9a-fA-F]+$/.test(value))
            return false;

        dispatch("hl.dsp.focus({ window = \"address:" + value + "\" })");
        return true;
    }

    function focusWorkspace(id) {
        const value = parseInt(id);
        if (!isNaN(value) && value > 0)
            dispatch("hl.dsp.focus({ workspace = " + value + " })");

    }

    function toggleSpecialWorkspace(name) {
        if (name === "magic")
            dispatch("hl.dsp.workspace.toggle_special(\"magic\")");

    }

    function refresh() {
        statusRefreshRequested();
    }

    function lookupWindowWorkspace(address) {
        const value = String(address || "");
        if (!/^0x[0-9a-fA-F]+$/.test(value))
            return ;

        if (lookup.running) {
            pendingLookupAddress = value;
            return ;
        }
        lookup.command = ["python3", scriptRoot + "/workspaces/window-for-address.py", value];
        lookup.running = true;
    }

    function activate(item) {
        if (!focusWindow(item.urgentAddress || alertWindowAddress))
            focusWorkspace(item.id);

        clearAlert(item.id);
        alertWindowAddress = "";
        statusRefreshRequested();
    }

    Process {
        id: lookup

        onExited: {
            if (root.pendingLookupAddress.length === 0)
                return ;

            const address = root.pendingLookupAddress;
            root.pendingLookupAddress = "";
            Qt.callLater(() => {
                return root.lookupWindowWorkspace(address);
            });
        }

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const info = this.text.trim().length > 0 ? JSON.parse(this.text.trim()) : {
                    };
                    const workspaceId = parseInt(info.workspace);
                    if (!isNaN(workspaceId) && workspaceId !== root.focusedWorkspaceId())
                        root.addAlert(workspaceId, info.address || "");

                } catch (error) {
                }
            }
        }

    }

    Connections {
        function onFocusedMonitorChanged() {
            root.focusedMonitorChanged();
        }

        function onRawEvent(event) {
            root.statusRefreshRequested();
            if (event.name === "workspace" || event.name === "workspacev2") {
                const activeId = parseInt(event.data.split(",")[0]);
                if (!isNaN(activeId))
                    root.clearAlert(activeId);

            } else if (event.name === "openwindow" || event.name === "closewindow") {
                root.privacyRefreshRequested();
            } else if (event.name === "urgent") {
                root.alertWindowAddress = event.data || "";
                root.lookupWindowWorkspace(root.alertWindowAddress);
                urgentSwitchDelay.restart();
            } else if (event.name === "activewindowv2") {
                root.lookupWindowWorkspace(event.data || "");
            }
        }

        target: Hyprland
    }

    Timer {
        interval: 550
        repeat: true
        running: true
        onTriggered: root.blinkOn = !root.blinkOn
    }

    Timer {
        id: urgentSwitchDelay

        interval: 120
        repeat: false
        onTriggered: {
            for (let i = 0; i < root.items.length; i++) {
                const item = root.items[i];
                if (!(item.urgent || root.hasAlert(item.id)))
                    continue;

                if (!item.active) {
                    root.activate(item);
                } else {
                    root.focusWindow(item.urgentAddress || root.alertWindowAddress);
                    root.clearAlert(item.id);
                    root.alertWindowAddress = "";
                    root.statusRefreshRequested();
                }
                break;
            }
        }
    }

}
