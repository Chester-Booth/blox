import QtQuick

// Pure graphics projection. Detection is useful even when the available
// vendor power action is not safe or not present.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool backendAvailable: false
    property var devices: []
    property int deviceCount: 0
    property int discreteCount: 0
    property string backend: ""
    property string mode: "unavailable"
    property string label: "GPU unavailable"
    property bool gpuOn: false
    property string gpuUtil: ""
    property string gpuTemp: ""
    property string vramUsed: ""
    property string vramTotal: ""
    property string controlReason: "no-supported-controller"
    property string permission: "not-required"
    property bool controlAvailable: false
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady && root.backendAvailable
    readonly property bool canChange: root.ready && root.controlAvailable
    readonly property var json: root.buildStatus()

    function capability() {
        let reason = null;
        let capabilityPermission = root.permission;
        if (!root.providerReady) {
            reason = "provider-not-ready";
            capabilityPermission = "unknown";
        } else if (!root.syncReady) {
            reason = "provider-loading";
            capabilityPermission = "unknown";
        } else if (!root.backendAvailable) {
            reason = "backend-unavailable";
            capabilityPermission = "unknown";
        } else if (!root.controlAvailable) {
            reason = root.controlReason || "no-supported-controller";
        }
        return {
            "available": root.providerReady && root.syncReady && root.backendAvailable,
            "ready": root.ready,
            "canChange": root.canChange,
            "permission": capabilityPermission,
            "reason": reason
        };
    }

    function buildStatus() {
        const capability = root.capability();
        let details = root.label;
        if (root.deviceCount > 0)
            details += "\n" + root.deviceCount + " graphics device" + (root.deviceCount === 1 ? "" : "s") + " detected";
        if (!root.controlAvailable && root.controlReason)
            details += "\nControl unavailable: " + root.controlReason;
        if (root.actionError.length > 0)
            details += "\nAction error: " + root.actionError;
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": root.busy,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "devices": root.devices,
            "deviceCount": root.deviceCount,
            "discreteCount": root.discreteCount,
            "backend": root.backend,
            "mode": root.mode,
            "label": root.label,
            "gpuOn": root.gpuOn,
            "gpuUtil": root.gpuUtil,
            "gpuTemp": root.gpuTemp,
            "vramUsed": root.vramUsed,
            "vramTotal": root.vramTotal,
            "controlReason": root.controlReason,
            "tooltip": details,
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
    onDeviceCountChanged: root.markChanged()
    onDiscreteCountChanged: root.markChanged()
    onBackendChanged: root.markChanged()
    onModeChanged: root.markChanged()
    onLabelChanged: root.markChanged()
    onGpuOnChanged: root.markChanged()
    onGpuUtilChanged: root.markChanged()
    onGpuTempChanged: root.markChanged()
    onVramUsedChanged: root.markChanged()
    onVramTotalChanged: root.markChanged()
    onControlReasonChanged: root.markChanged()
    onPermissionChanged: root.markChanged()
    onControlAvailableChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
