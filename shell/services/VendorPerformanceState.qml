import QtQuick

// Pure vendor-performance projection. The vendor owner is optional and does
// not participate in the generic power-profile policy.
Item {
    id: root

    property bool providerReady: false
    property bool syncReady: false
    property bool backendAvailable: false
    property string vendor: ""
    property string profile: "unavailable"
    property string profileLabel: ""
    property var profiles: []
    property bool busy: false
    property string actionError: ""
    property int revision: 0
    property real observedAtMs: 0
    readonly property bool ready: root.providerReady && root.syncReady && root.backendAvailable
    readonly property bool canChange: root.ready && root.profiles.length > 0
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
        } else if (root.profiles.length === 0) {
            reason = "profile-unavailable";
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
        let details = "Vendor performance unavailable";
        if (root.ready && root.profile !== "unavailable")
            details = (root.vendor || "Vendor") + " profile: " + (root.profileLabel || root.profile);
        if (root.actionError.length > 0)
            details += "\nAction error: " + root.actionError;
        return {
            "schemaVersion": 1,
            "providerRevision": root.revision,
            "observedAtMs": root.observedAtMs,
            "stale": !capability.ready,
            "busy": root.busy,
            "errorCode": root.actionError.length > 0 ? root.actionError : capability.reason,
            "vendor": root.vendor,
            "profile": root.profile,
            "profileLabel": root.profileLabel,
            "profiles": root.profiles,
            "details": details,
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
    onVendorChanged: root.markChanged()
    onProfileChanged: root.markChanged()
    onProfileLabelChanged: root.markChanged()
    onProfilesChanged: root.markChanged()
    onBusyChanged: root.markChanged()
    onActionErrorChanged: root.markChanged()
    Component.onCompleted: root.markChanged()
}
