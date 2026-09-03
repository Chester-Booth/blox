import QtQuick
import Quickshell

// Guard the optional power-profiles-daemon service. A loaded module with no
// performance profile remains a usable, non-actionable status.
Scope {
    id: root

    property int interval: 60000
    property url providerSource: Qt.resolvedUrl("PowerProfilesProvider.qml")
    property var json: ({
    })
    property bool ok: true
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? String(providerLoader.item.lastError || "") : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error

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
        return root.providerReady && providerLoader.item.setProfile(id);
    }

    Loader {
        id: providerLoader

        active: true
        source: root.providerSource
        onLoaded: {
            item.interval = root.interval;
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
