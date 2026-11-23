import qs.shared
import QtQuick
import "ActionContract.js" as ActionContract
import Quickshell

// Guard the optional power-profiles-daemon service. A loaded module with no
// performance profile remains a usable, non-actionable status.
Scope {
    id: root

    property var policy: null
    property var batteryStatus: null
    property int interval: 60000
    property url providerSource: Qt.resolvedUrl("PowerProfilesProvider.qml")
    readonly property bool nativeProvider: root.providerSource === Qt.resolvedUrl("PowerProfilesProvider.qml")
    property bool nativeActivated: false
    property var json: ({
    })
    property bool ok: true
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? String(providerLoader.item.lastError || "") : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error || (root.nativeProvider && !root.nativeActivated && availability.ready && !availability.available)

    readonly property var loadingStatus: ({
        "profile": "unavailable",
        "profiles": [],
        "profileServiceAvailable": false,
        "onBattery": false,
        "degradationReason": "none",
        "tooltip": "Waiting for power profiles",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-loading",
        "capability": {
            "available": true,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "provider-loading"
        }
    })

    readonly property var unavailableStatus: ({
        "profile": "unavailable",
        "profiles": [],
        "profileServiceAvailable": false,
        "onBattery": false,
        "degradationReason": "none",
        "tooltip": "Power profiles unavailable",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-unavailable",
        "capability": {
            "available": false,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "provider-unavailable"
        }
    })

    function syncJson() {
        if (root.providerReady && providerLoader.item)
            root.json = providerLoader.item.json;
        else if (root.providerFailed)
            root.json = root.unavailableStatus;
        else
            root.json = root.loadingStatus;
    }

    function refresh() {
        if (root.providerReady) {
            providerLoader.item.interval = root.interval;
            providerLoader.item.refresh();
        }
    }

    function setProfile(id) {
        return policyOwner.setManualProfile(id);
    }

    PowerProfilePolicy {
        id: policyOwner
        provider: root.providerReady ? providerLoader.item : null
        policy: root.policy
        onBattery: root.json.onBattery === true
        canChange: !!root.json.capability && root.json.capability.canChange === true
            && (!root.nativeProvider || (!!root.batteryStatus && !!root.batteryStatus.capability && root.batteryStatus.capability.ready === true))
        busy: root.json.busy === true
        currentProfile: String(root.json.profile || "unavailable")
    }

    function action(operation, value) {
        const status = root.json || {};
        const blocked = ActionContract.blockedCode(status, status.capability && status.capability.canChange);
        if (blocked)
            return ActionContract.result(false, blocked, "the action is unavailable");
        const beforeRevision = Number(status.providerRevision || 0);
        if (operation !== "set" || (status.profiles || []).indexOf(String(value)) < 0)
            return ActionContract.result(false, "invalid-data", "unsupported power profile");
        const accepted = root.setProfile(value);
        if (!accepted)
            return ActionContract.result(false, "failed", "the provider rejected the action");
        return ActionContract.accepted(operation, value, root.json || {}, beforeRevision);
    }

    NativeServiceAvailability {
        id: availability
        service: "org.freedesktop.UPower.PowerProfiles"
        alternateService: "net.hadess.PowerProfiles"
        enabled: root.nativeProvider && !root.nativeActivated
        onServiceFound: { if (root.nativeProvider) root.nativeActivated = true; }
    }

    Loader {
        id: providerLoader

        active: !root.nativeProvider || root.nativeActivated
        source: root.providerSource
        onLoaded: {
            item.interval = root.interval;
            if (root.nativeProvider) item.batteryStatus = Qt.binding(() => root.batteryStatus);
            root.syncJson();
        }
        onStatusChanged: root.syncJson()
    }

    Connections {
        target: providerLoader.item
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncJson(); }
    }

    onProviderReadyChanged: root.syncJson()
    onProviderFailedChanged: root.syncJson()
    onProviderSourceChanged: root.syncJson()
    onIntervalChanged: root.refresh()
    Component.onCompleted: root.syncJson()
}
