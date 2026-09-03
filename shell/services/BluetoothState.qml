import QtQuick

// Pure Bluetooth projection. Device names are safe display data; addresses
// never enter the status, action result or diagnostic surface.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool adapterAvailable: false
    property bool adapterEnabled: false
    property bool adapterBlocked: false
    property var connectedNames: []
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady && root.adapterAvailable
    readonly property bool canChange: root.ready && !root.adapterBlocked
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
        } else if (!root.adapterAvailable) {
            reason = "no-adapter";
            permission = "unknown";
        } else if (root.adapterBlocked) {
            reason = "permission-denied";
            permission = "denied";
        }
        return {
            "available": root.providerReady && (!root.syncReady || root.adapterAvailable),
            "ready": root.ready,
            "canChange": root.canChange,
            "permission": permission,
            "reason": reason
        };
    }

    function buildStatus() {
        const capability = root.capability();
        let icon = "󰂯";
        let statusClass = "unavailable";
        let summary = "Bluetooth unavailable";
        let details = "Bluetooth is unavailable";
        if (!root.syncReady && root.providerReady) {
            statusClass = "loading";
            summary = "Bluetooth loading";
            details = "Waiting for BlueZ";
        } else if (capability.available) {
            if (!root.adapterEnabled) {
                icon = "󰂲";
                statusClass = "disabled";
                summary = "Bluetooth off";
                details = "Bluetooth is off";
            } else if (root.connectedNames.length > 0) {
                icon = "󰂱";
                statusClass = "connected";
                summary = root.connectedNames[0];
                details = "Connected: " + root.connectedNames.join(", ");
            } else {
                statusClass = "on";
                summary = "Bluetooth on";
                details = "No connected devices";
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
            "summary": summary,
            "enabled": root.adapterEnabled,
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
    onAdapterAvailableChanged: root.markChanged()
    onAdapterEnabledChanged: root.markChanged()
    onAdapterBlockedChanged: root.markChanged()
    onConnectedNamesChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
