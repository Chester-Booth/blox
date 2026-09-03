import QtQuick

// Pure power-profile projection. A missing performance profile is a valid
// ready state and must not be confused with a missing UPower module.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool profileServiceAvailable: false
    property bool onBattery: false
    property string profile: "unavailable"
    property string degradationReason: "none"
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    property var json: ({
    })

    readonly property bool ready: root.providerReady && root.syncReady
    readonly property bool canChange: root.ready && root.profileServiceAvailable

    function capability() {
        let reason = null;
        let permission = "not-required";
        const ready = root.providerReady && root.syncReady;
        const canChange = ready && root.profileServiceAvailable;
        if (!root.providerReady) {
            reason = "provider-not-ready";
            permission = "unknown";
        } else if (!root.syncReady) {
            reason = "provider-loading";
            permission = "unknown";
        } else if (!root.profileServiceAvailable) {
            reason = "profile-unavailable";
        }
        return {
            "available": root.providerReady,
            "ready": ready,
            "canChange": canChange,
            "permission": permission,
            "reason": reason
        };
    }

    function buildStatus() {
        const capability = root.capability();
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": root.busy,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "profile": root.profile,
            "onBattery": root.onBattery,
            "profileServiceAvailable": root.profileServiceAvailable,
            "degradationReason": root.degradationReason,
            "profiles": ["power-saver", "balanced", "performance"],
            "tooltip": root.profile === "unavailable" ? "Power profiles unavailable" : "Power profile: " + root.profile,
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
    onProfileServiceAvailableChanged: root.markChanged()
    onOnBatteryChanged: root.markChanged()
    onProfileChanged: root.markChanged()
    onDegradationReasonChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
