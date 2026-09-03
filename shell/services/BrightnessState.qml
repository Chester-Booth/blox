import QtQuick

// Pure display-brightness projection. The provider supplies discovered
// backlights and optional DDC metadata, so a fixed device name is never part
// of the UI contract.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool backendAvailable: false
    property string device: ""
    property var backlights: []
    property int percent: 0
    property string blueLightMode: "auto"
    property bool blueLightActive: false
    property bool ddcAvailable: false
    property int ddcDisplayCount: 0
    property string ddcReason: "command-unavailable"
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    property var json: ({
    })

    readonly property bool ready: root.providerReady && root.syncReady && root.backendAvailable
    readonly property bool backlightAvailable: root.device.length > 0
    readonly property bool canChange: root.ready && root.backlightAvailable

    function boundedPercent() {
        const value = Number(root.percent);
        if (!isFinite(value))
            return 0;
        return Math.max(0, Math.min(100, Math.round(value)));
    }

    function brightnessIcon(value) {
        const icons = ["󰃚", "󰃛", "󰃜", "󰃝", "󰃞", "󰃟", "󰃠"];
        return icons[Math.min(6, Math.floor(value / 17))];
    }

    function capability() {
        let reason = null;
        let permission = "granted";
        const ready = root.providerReady && root.syncReady && root.backendAvailable;
        const canChange = ready && root.backlightAvailable;
        if (!root.providerReady) {
            reason = "provider-not-ready";
            permission = "unknown";
        } else if (!root.syncReady) {
            reason = "provider-loading";
            permission = "unknown";
        } else if (!root.backendAvailable) {
            reason = "command-unavailable";
            permission = "unknown";
        } else if (!root.backlightAvailable) {
            reason = "device-unavailable";
            permission = "not-required";
        }
        return {
            "available": root.providerReady && root.syncReady && root.backendAvailable,
            "ready": ready,
            "canChange": canChange,
            "permission": permission,
            "reason": reason
        };
    }

    function buildStatus() {
        const capability = root.capability();
        const percent = root.boundedPercent();
        let details = "Brightness status unavailable";
        if (capability.ready && root.backlightAvailable)
            details = "Brightness: " + percent + "%\nBlue light: " + root.blueLightMode + (root.blueLightActive ? " active" : " inactive");
        else if (root.syncReady && root.backendAvailable && !root.backlightAvailable)
            details = "No backlight device";
        if (root.actionError.length > 0)
            details += "\nAction error: " + root.actionError;
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": root.busy,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "icon": root.brightnessIcon(percent),
            "percent": percent,
            "blueLightMode": root.blueLightMode,
            "blueLightActive": root.blueLightActive,
            "device": root.device,
            "backlightCount": root.backlights.length,
            "backlights": root.backlights,
            "ddcAvailable": root.ddcAvailable,
            "ddcDisplayCount": root.ddcDisplayCount,
            "ddcReason": root.ddcReason,
            "details": details,
            "tooltip": details,
            "capability": capability
        };
    }

    function markChanged() {
        root.revision += 1;
        root.observedAtMs = Date.now();
        root.json = root.buildStatus();
    }

    onProviderReadyChanged: root.markChanged()
    onSyncReadyChanged: root.markChanged()
    onBackendAvailableChanged: root.markChanged()
    onDeviceChanged: root.markChanged()
    onBacklightsChanged: root.markChanged()
    onPercentChanged: root.markChanged()
    onBlueLightModeChanged: root.markChanged()
    onBlueLightActiveChanged: root.markChanged()
    onDdcAvailableChanged: root.markChanged()
    onDdcDisplayCountChanged: root.markChanged()
    onDdcReasonChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
