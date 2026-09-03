import QtQuick

// Pure touchpad projection. Device names come from the compositor probe and
// are never fixed in the UI or action contract.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool backendAvailable: false
    property var devices: []
    property string device: ""
    property bool touchpadEnabled: true
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady && root.backendAvailable
    readonly property bool canChange: root.ready && root.devices.length > 0
    readonly property var json: root.buildStatus()

    function capability() {
        let reason = null;
        let permission = "not-required";
        if (!root.providerReady) {
            reason = "provider-not-ready";
            permission = "unknown";
        } else if (!root.syncReady) {
            reason = "provider-loading";
            permission = "unknown";
        } else if (!root.backendAvailable) {
            reason = "backend-unavailable";
            permission = "unknown";
        } else if (root.devices.length === 0) {
            reason = "device-unavailable";
        }
        return {
            "available": root.providerReady && root.syncReady && root.backendAvailable,
            "ready": root.ready,
            "canChange": root.canChange,
            "permission": permission,
            "reason": reason
        };
    }

    function buildStatus() {
        const capability = root.capability();
        let icon = "󰟸";
        let statusClass = "unavailable";
        let summary = "Touchpad unavailable";
        let details = "Touchpad discovery unavailable";
        if (root.providerReady && !root.syncReady) {
            statusClass = "loading";
            summary = "Touchpad loading";
            details = "Waiting for the compositor device list";
        } else if (capability.available) {
            if (root.devices.length === 0) {
                details = "No touchpad device was found";
            } else if (root.touchpadEnabled) {
                statusClass = "enabled";
                summary = "Touchpad enabled";
                details = root.device || "Touchpad enabled";
            } else {
                icon = "󰤳";
                statusClass = "disabled";
                summary = "Touchpad disabled";
                details = root.device || "Touchpad disabled";
            }
        }
        if (root.actionError.length > 0)
            details += "\nAction error: " + root.actionError;
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": root.busy,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "icon": icon,
            "class": statusClass,
            "device": root.device,
            "devices": root.devices,
            "touchpadCount": root.devices.length,
            "enabled": root.touchpadEnabled,
            "details": details,
            "tooltip": summary + "\n" + details,
            "capability": capability
        };
    }

    function markChanged() {
        root.revision += 1;
        root.observedAtMs = Date.now();
    }

    onProviderReadyChanged: root.markChanged()
    onSyncReadyChanged: root.markChanged()
    onBackendAvailableChanged: root.markChanged()
    onDevicesChanged: root.markChanged()
    onDeviceChanged: root.markChanged()
    onTouchpadEnabledChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
