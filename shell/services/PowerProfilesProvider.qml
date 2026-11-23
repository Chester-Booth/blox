import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// The native plugin owns profile changes. A bounded read-only D-Bus probe
// distinguishes a daemon without a performance profile from a missing daemon.
Scope {
    id: root

    property var profilesService: PowerProfiles
    property var upowerService: null
    property var batteryStatus: null
    property int interval: 60000
    property bool syncReady: false
    property string pendingProfile: ""
    property string actionError: ""
    property var availableProfiles: []
    property string discoveryRaw: ""
    property int discoveryBackend: 0
    property string discoveryOwner: ""
    property bool discoveryTimedOut: false
    property int discoveryTimeout: 5000

    function acceptProfileDiscovery(output) {
        try {
            const reply = JSON.parse(output);
            if (reply.type !== "aa{sv}" || !Array.isArray(reply.data)) throw new Error("invalid profiles");
            const names = [];
            for (const entry of reply.data) {
                const profile = entry.Profile;
                if (!profile || profile.type !== "s" || ["power-saver", "balanced", "performance"].indexOf(profile.data) < 0)
                    throw new Error("invalid profile");
                if (names.indexOf(profile.data) < 0) names.push(profile.data);
            }
            root.availableProfiles = names;
        } catch (error) {
            root.availableProfiles = [];
        }
        root.syncReady = true;
        root.syncAction();
        state.markChanged();
    }

    function refreshProfileDiscovery() {
        if (!root.providerReady || discovery.running) return;
        root.discoveryBackend = 0;
        root.discoveryOwner = availability.owner;
        root.discoveryRaw = "";
        root.discoveryTimedOut = false;
        discovery.running = true;
    }

    function resetProfileDiscovery() {
        root.availableProfiles = [];
        root.syncReady = false;
        if (root.pendingProfile.length > 0) {
            root.pendingProfile = "";
            actionTimeout.stop();
            root.actionError = "profile-unavailable";
        }
        root.refreshProfileDiscovery();
    }

    onProfilesServiceChanged: root.resetProfileDiscovery()
    readonly property bool providerReady: root.profilesService !== null && availability.available
    readonly property bool actionBusy: root.pendingProfile.length > 0
    readonly property int revision: state.revision
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property string lastError: root.actionError
    property var json: ({
    })

    NativeServiceAvailability {
        id: availability
        objectName: "power-profile-service-availability"
        service: "org.freedesktop.UPower.PowerProfiles"
        alternateService: "net.hadess.PowerProfiles"
        enabled: root.profilesService === PowerProfiles
        onOwnerChanged: root.resetProfileDiscovery()
    }

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
        root.refreshProfileDiscovery();
    }

    function setProfile(id) {
        const value = String(id || "");
        const enumValue = root.profileValue(value);
        if (!state.canChange || enumValue < 0 || root.availableProfiles.indexOf(value) < 0 || root.actionBusy)
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
        profileServiceAvailable: root.providerReady && root.availableProfiles.length > 0
        supportedProfiles: root.providerReady ? root.availableProfiles : []
        onBattery: root.batteryStatus ? root.batteryStatus.onBattery === true : root.upowerService ? root.upowerService.onBattery === true : false
        profile: state.profileServiceAvailable && root.profilesService ? root.profileName(root.profilesService.profile) : "unavailable"
        degradationReason: root.profilesService ? String(root.profilesService.degradationReason || "none") : "none"
        busy: root.actionBusy
        actionError: root.actionError
    }

    function syncJson() {
        root.json = state.json;
    }

    Process {
        id: discovery
        command: root.discoveryBackend === 0
            ? ["busctl", "--system", "--json=short", "get-property", "org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles", "Profiles"]
            : ["busctl", "--system", "--json=short", "get-property", "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles", "Profiles"]
        onStarted: discoveryWatchdog.restart()
        stdout: StdioCollector { onStreamFinished: root.discoveryRaw = this.text }
        onExited: (exitCode, exitStatus) => {
            discoveryWatchdog.stop();
            discoveryKill.stop();
            if (!root.providerReady || root.discoveryOwner !== availability.owner) {
                root.availableProfiles = [];
                root.syncReady = false;
                root.refreshProfileDiscovery();
                return;
            }
            if (exitCode === 0 && exitStatus === 0 && !root.discoveryTimedOut) {
                root.acceptProfileDiscovery(root.discoveryRaw);
            } else if (root.discoveryBackend === 0 && !root.discoveryTimedOut) {
                root.discoveryBackend = 1;
                root.discoveryRaw = "";
                discovery.running = true;
            } else {
                root.acceptProfileDiscovery("");
            }
        }
    }
    Timer {
        id: discoveryWatchdog
        interval: Math.max(1, root.discoveryTimeout)
        onTriggered: {
            root.discoveryTimedOut = true;
            discovery.signal(15);
            discoveryKill.restart();
        }
    }
    Timer {
        id: discoveryKill
        interval: 1000
        onTriggered: { if (discovery.running) discovery.signal(9); }
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
