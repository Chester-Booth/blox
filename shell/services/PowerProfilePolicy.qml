import QtQuick

// A manual selection lasts until the source or saved policy changes.
QtObject {
    id: root

    property var provider: null
    property var policy: null
    property bool onBattery: false
    property bool canChange: false
    property bool busy: false
    property string currentProfile: "unavailable"
    property bool manualOverride: false
    property string attemptedProfile: ""
    readonly property string policyKey: JSON.stringify([policy ? policy.acProfile || null : null, policy ? policy.batteryProfile || null : null])
    readonly property string desiredProfile: policy ? String((onBattery ? policy.batteryProfile : policy.acProfile) || "") : ""

    function reconcile() {
        const desired = root.policy ? String((root.onBattery ? root.policy.batteryProfile : root.policy.acProfile) || "") : "";
        if (!root.provider || !root.canChange || root.busy || root.manualOverride
                || !desired || desired === root.currentProfile || desired === root.attemptedProfile)
            return false;
        root.attemptedProfile = desired;
        return root.provider.setProfile(desired);
    }

    function reset() {
        root.manualOverride = false;
        root.attemptedProfile = "";
        root.reconcile();
    }

    function setManualProfile(id) {
        if (!root.provider)
            return false;
        const previous = root.manualOverride;
        root.manualOverride = true;
        if (root.provider.setProfile(id))
            return true;
        root.manualOverride = previous;
        return false;
    }

    onPolicyKeyChanged: reset()
    onOnBatteryChanged: reset()
    onCanChangeChanged: {
        root.attemptedProfile = "";
        root.reconcile();
    }
    onBusyChanged: reconcile()
    onCurrentProfileChanged: reconcile()
    onProviderChanged: reconcile()
}
