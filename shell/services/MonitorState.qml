import QtQuick

// Pure projection of active Hyprland monitors and their current-resolution rates.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool backendAvailable: false
    property var monitors: []
    property bool busy: false
    property string errorCode: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady && root.backendAvailable
    readonly property bool canChange: root.ready && root.monitors.some(monitor => monitor.canChange === true)
    readonly property var json: ({
        "schemaVersion": 1,
        "providerRevision": root.revision,
        "observedAtMs": root.observedAtMs,
        "stale": !root.ready,
        "busy": root.busy,
        "errorCode": root.errorCode.length > 0 ? root.errorCode : null,
        "monitors": root.monitors,
        "monitorCount": root.monitors.length,
        "capability": {
            "available": root.providerReady && root.syncReady && root.backendAvailable,
            "ready": root.ready,
            "canChange": root.canChange,
            "permission": root.ready ? "not-required" : "unknown",
            "reason": !root.providerReady ? "provider-not-ready" : !root.syncReady ? "provider-loading" : !root.backendAvailable ? (root.errorCode || "backend-unavailable") : root.canChange ? null : root.monitors.length > 0 ? "no-refresh-choice" : "no-active-monitor"
        }
    })

    function markChanged() {
        root.revision += 1;
        root.observedAtMs = Date.now();
    }

    onProviderReadyChanged: markChanged()
    onSyncReadyChanged: markChanged()
    onBackendAvailableChanged: markChanged()
    onMonitorsChanged: markChanged()
    onBusyChanged: markChanged()
    onErrorCodeChanged: markChanged()
    Component.onCompleted: markChanged()
}
