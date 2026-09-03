import QtQuick
import Quickshell
import Quickshell.Services.UPower

// Native power-profiles-daemon adapter exposed by Quickshell's UPower
// service. The plugin has no explicit ready flag, so a performance profile is
// used as the daemon capability signal; absence remains typed and harmless.
Scope {
    id: root

    property var profilesService: PowerProfiles
    property var upowerService: UPower
    property int interval: 60000
    property bool syncReady: false
    property string pendingProfile: ""
    property string actionError: ""
    readonly property bool providerReady: root.profilesService !== null
    readonly property bool actionBusy: root.pendingProfile.length > 0
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError
    property var json: ({
    })

    function profileName(value) {
        if (value === PowerProfile.PowerSaver)
            return "power-saver";
        if (value === PowerProfile.Balanced)
            return "balanced";
        if (value === PowerProfile.Performance)
            return "performance";
        return "unavailable";
    }

    function profileValue(id) {
        if (id === "power-saver")
            return PowerProfile.PowerSaver;
        if (id === "balanced")
            return PowerProfile.Balanced;
        if (id === "performance")
            return PowerProfile.Performance;
        return -1;
    }

    function syncAction() {
        if (root.pendingProfile.length === 0)
            return;
        if (!state.canChange) {
            root.pendingProfile = "";
            actionTimeout.stop();
            root.actionError = "profile-unavailable";
        } else if (state.profile === root.pendingProfile) {
            root.pendingProfile = "";
            actionTimeout.stop();
        }
    }

    function refresh() {
        root.syncAction();
        state.markChanged();
    }

    function setProfile(id) {
        const value = String(id || "");
        const enumValue = root.profileValue(value);
        if (!state.canChange || enumValue < 0 || root.actionBusy)
            return false;
        root.actionError = "";
        root.pendingProfile = value;
        actionTimeout.restart();
        root.profilesService.profile = enumValue;
        root.syncAction();
        return true;
    }

    PowerProfileState {
        id: state

        providerReady: root.providerReady
        syncReady: root.syncReady
        profileServiceAvailable: root.profilesService && root.profilesService.hasPerformanceProfile === true
        onBattery: root.upowerService ? root.upowerService.onBattery === true : false
        profile: state.profileServiceAvailable && root.profilesService ? root.profileName(root.profilesService.profile) : "unavailable"
        degradationReason: root.profilesService ? String(root.profilesService.degradationReason || "none") : "none"
        busy: root.actionBusy
        actionError: root.actionError
    }

    function syncJson() {
        root.json = state.json;
    }

    Timer {
        id: initialSync

        interval: 1000
        repeat: false
        running: root.providerReady && !root.syncReady
        onTriggered: {
            root.syncReady = true;
            root.refresh();
        }
    }

    Timer {
        id: poll

        interval: Math.max(1000, root.interval)
        running: root.providerReady && root.interval > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: actionTimeout

        interval: 5000
        repeat: false
        onTriggered: {
            if (root.pendingProfile.length > 0) {
                root.pendingProfile = "";
                root.actionError = "timeout";
                root.refresh();
            }
        }
    }

    Connections {
        target: state
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncJson(); }
    }

    Connections {
        target: root.profilesService
        ignoreUnknownSignals: true

        function onProfileChanged() { root.refresh(); }
        function onHasPerformanceProfileChanged() { root.refresh(); }
        function onDegradationReasonChanged() { root.refresh(); }
    }

    Connections {
        target: root.upowerService
        ignoreUnknownSignals: true

        function onOnBatteryChanged() { root.refresh(); }
    }

    Component.onCompleted: root.syncJson()
}
