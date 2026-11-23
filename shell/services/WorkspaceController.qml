import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: root

    property string scriptRoot: ""
    property var hyprland: Hyprland
    property var items: []
    property var special: ({
    })
    property string alertWorkspaceIds: ","
    property string alertWindowAddress: ""
    property var alertLookupRequests: ({})
    property var activeLookupRequest: null
    property var pendingFocusLookup: null
    property var pendingUrgentLookup: null
    readonly property string pendingLookupAddress: pendingUrgentLookup ? pendingUrgentLookup.address
        : pendingFocusLookup ? pendingFocusLookup.address : ""
    property int focusLookupRevision: 0
    property int urgentLookupRevision: 0
    property int workspaceRevision: 0
    property bool lookupExited: false
    property bool lookupOutputFinished: false
    property string lookupOutput: ""
    property bool lookupSucceeded: false
    property bool blinkOn: true
    property bool statusRefreshQueued: false

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
        return hyprland.focusedWorkspace ? hyprland.focusedWorkspace.id : activeWorkspaceId();
    }

    function hasAlert(id) {
        return alertWorkspaceIds.indexOf("," + id + ",") >= 0;
    }

    function addAlert(id, address, request) {
        if (id <= 0)
            return ;

        const previous = alertLookupRequests[id];
        if (request && request.purpose === "focus" && previous && previous.purpose === "urgent") return;
        const requests = Object.assign({}, alertLookupRequests);
        requests[id] = request || {purpose: "urgent", address: address};
        alertLookupRequests = requests;

        if (!hasAlert(id))
            alertWorkspaceIds += id + ",";

        if ((!request || request.purpose !== "focus") && address !== undefined && address.length > 0)
            alertWindowAddress = address;

        urgentSwitchDelay.restart();
    }

    function clearAlert(id) {
        alertWorkspaceIds = alertWorkspaceIds.replace("," + id + ",", ",");
        const requests = Object.assign({}, alertLookupRequests);
        delete requests[id];
        alertLookupRequests = requests;
    }

    function dispatch(expression) {
        Quickshell.execDetached(["hyprctl", "dispatch", expression]);
    }

    // Socket events omit 0x while the clients snapshot includes it.
    function normaliseWindowAddress(address) {
        const value = String(address || "");
        if (!/^(0x)?[0-9a-fA-F]+$/.test(value)) return "";
        return value.startsWith("0x") ? value : "0x" + value;
    }

    function focusWindow(address) {
        const value = normaliseWindowAddress(address);
        if (!value)
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

    // Focus affects the chosen application and titles appear in workspace tooltips.
    // Keep both event versions, but batch a compositor update into one snapshot.
    function affectsStatus(name) {
        switch (name) {
        case "workspace": case "workspacev2":
        case "createworkspace": case "createworkspacev2":
        case "destroyworkspace": case "destroyworkspacev2":
        case "moveworkspace": case "moveworkspacev2":
        case "renameworkspace":
        case "activespecial": case "activespecialv2":
        case "focusedmon": case "focusedmonv2":
        case "monitoradded": case "monitoraddedv2":
        case "monitorremoved": case "monitorremovedv2":
        case "openwindow": case "closewindow":
        case "movewindow": case "movewindowv2":
        case "activewindow": case "activewindowv2":
        case "windowtitle": case "windowtitlev2":
        case "urgent": case "pin": case "configreloaded":
            return true;
        default:
            return false;
        }
    }

    function flushStatusRefresh() {
        statusRefreshQueued = false;
        statusRefreshRequested();
    }

    function queueStatusRefresh() {
        if (statusRefreshQueued) return;
        statusRefreshQueued = true;
        Qt.callLater(flushStatusRefresh);
    }

    function handleRawEvent(event) {
        if (affectsStatus(event.name)) queueStatusRefresh();
        if (event.name === "workspace" || event.name === "workspacev2") {
            invalidateFocusLookup();
            const activeId = parseInt(event.data.split(",")[0]);
            if (!isNaN(activeId)) clearAlert(activeId);
        } else if (event.name === "openwindow" || event.name === "closewindow") {
            if (event.name === "closewindow") invalidateFocusLookup();
            privacyRefreshRequested();
        } else if (event.name === "urgent") {
            alertWindowAddress = normaliseWindowAddress(event.data);
            lookupWindowWorkspace(alertWindowAddress, "urgent");
            urgentSwitchDelay.restart();
        } else if (event.name === "activewindowv2") {
            lookupWindowWorkspace(event.data || "", "focus");
        } else if (["focusedmon", "focusedmonv2", "activespecial", "activespecialv2",
                    "movewindow", "movewindowv2"].indexOf(event.name) >= 0) {
            invalidateFocusLookup();
        }
    }

    function invalidateFocusLookup() {
        workspaceRevision++;
        focusLookupRevision++;
        pendingFocusLookup = null;
        clearFocusAlerts();
    }

    function clearFocusAlerts() {
        for (const id of Object.keys(alertLookupRequests)) {
            if (alertLookupRequests[id].purpose === "focus") clearAlert(id);
        }
    }

    function lookupWindowWorkspace(address, purpose) {
        const urgent = purpose === "urgent";
        if (!urgent) {
            focusLookupRevision++;
            pendingFocusLookup = null;
            clearFocusAlerts();
        }
        const value = normaliseWindowAddress(address);
        if (!value) return;
        const request = {address: value, purpose: urgent ? "urgent" : "focus",
            revision: urgent ? ++urgentLookupRevision : focusLookupRevision,
            workspaceRevision: workspaceRevision, workspaceId: focusedWorkspaceId()};
        if (urgent) pendingUrgentLookup = request;
        else pendingFocusLookup = request;
        drainLookups();
    }

    // Read the latest pending state when the previous process and its pipe finish.
    function drainLookups() {
        if (activeLookupRequest || lookup.running) return;
        const request = pendingUrgentLookup || pendingFocusLookup;
        if (!request) return;
        if (request.purpose === "urgent") pendingUrgentLookup = null;
        else pendingFocusLookup = null;
        activeLookupRequest = request;
        lookupExited = false;
        lookupOutputFinished = false;
        lookupSucceeded = false;
        lookupOutput = "";
        lookup.command = ["python3", scriptRoot + "/workspaces/window-for-address.py", request.address];
        lookup.running = true;
    }

    function finishLookup() {
        if (!activeLookupRequest || !lookupExited || !lookupOutputFinished) return;
        const request = activeLookupRequest;
        const current = request.purpose === "urgent"
            ? request.revision === urgentLookupRevision
            : request.revision === focusLookupRevision && request.workspaceRevision === workspaceRevision
                && request.workspaceId === focusedWorkspaceId();
        if (lookupSucceeded && current) {
            try {
                const info = JSON.parse(lookupOutput);
                const workspaceId = parseInt(info.workspace);
                if (normaliseWindowAddress(info.address) === request.address
                        && !isNaN(workspaceId) && workspaceId !== focusedWorkspaceId())
                    addAlert(workspaceId, request.address, request);
            } catch (error) { }
        }
        activeLookupRequest = null;
        Qt.callLater(drainLookups);
    }

    // Quickshell reports a failed exec through runningChanged without exited.
    function finishFailedLookupStart() {
        if (!activeLookupRequest || lookup.running || lookupExited) return;
        activeLookupRequest = null;
        Qt.callLater(drainLookups);
    }

    function activate(item) {
        const alert = alertLookupRequests[item.id];
        if (!focusWindow(item.urgentAddress || (alert ? alert.address : "") || alertWindowAddress))
            focusWorkspace(item.id);

        clearAlert(item.id);
        alertWindowAddress = "";
        statusRefreshRequested();
    }

    Process {
        id: lookup

        onRunningChanged: if (!running) Qt.callLater(root.finishFailedLookupStart)
        onExited: (code, status) => {
            root.lookupExited = true;
            root.lookupSucceeded = code === 0 && status === 0;
            root.finishLookup();
        }

        stdout: StdioCollector {
            onStreamFinished: {
                root.lookupOutput = this.text;
                root.lookupOutputFinished = true;
                root.finishLookup();
            }
        }

    }

    Connections {
        function onFocusedMonitorChanged() {
            root.invalidateFocusLookup();
            root.focusedMonitorChanged();
        }

        function onFocusedWorkspaceChanged() { root.invalidateFocusLookup(); }

        function onRawEvent(event) {
            root.handleRawEvent(event);
        }

        target: root.hyprland
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
                    const alert = root.alertLookupRequests[item.id];
                    root.focusWindow(item.urgentAddress || (alert ? alert.address : "") || root.alertWindowAddress);
                    root.clearAlert(item.id);
                    root.alertWindowAddress = "";
                    root.statusRefreshRequested();
                }
                break;
            }
        }
    }

}
