import qs.shared
import QtQuick
import Quickshell
import Quickshell.Io

// Guard the optional UPower plugin so a missing service or module cannot stop
// shell startup. The loaded provider owns all battery status reads.
Scope {
    id: root

    property int interval: 30000
    property url providerSource: Qt.resolvedUrl("UPowerProvider.qml")
    readonly property bool nativeProvider: root.providerSource === Qt.resolvedUrl("UPowerProvider.qml")
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
        "icon": "󰚥",
        "class": "loading",
        "capacity": "",
        "status": "Loading",
        "timeLabel": "N/A",
        "tooltip": "Waiting for UPower",
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
        "icon": "󰚥",
        "class": "unavailable",
        "capacity": "",
        "status": "Unknown",
        "timeLabel": "N/A",
        "tooltip": "Power provider unavailable",
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

    function refresh() {
        if (root.providerReady) {
            providerLoader.item.interval = root.interval;
            providerLoader.item.refresh();
        }
    }

    function syncJson() {
        if (root.providerReady && providerLoader.item)
            root.json = providerLoader.item.json;
        else if (root.providerFailed)
            root.json = root.unavailableStatus;
        else
            root.json = root.loadingStatus;
    }

    // UPower is D-Bus activated. Checking its owner alone never starts it.
    Process {
        id: activation
        objectName: "upower-activation"
        command: ["busctl", "--system", "--timeout=5s", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "StartServiceByName", "su", "org.freedesktop.UPower", "0"]
        onExited: availability.refresh()
    }

    NativeServiceAvailability {
        id: availability
        service: "org.freedesktop.UPower"
        enabled: root.nativeProvider && !root.nativeActivated
        onServiceFound: { if (root.nativeProvider) root.nativeActivated = true; }
    }

    Loader {
        id: providerLoader

        active: !root.nativeProvider || root.nativeActivated
        source: root.providerSource
        onLoaded: {
            item.interval = root.interval;
            root.syncJson();
        }
    }

    Connections {
        target: providerLoader.item
        ignoreUnknownSignals: true

        function onJsonChanged() { root.syncJson(); }
    }

    onProviderReadyChanged: root.syncJson()
    onProviderFailedChanged: root.syncJson()
    onProviderSourceChanged: root.syncJson()
    Component.onCompleted: {
        root.syncJson();
        if (root.nativeProvider)
            activation.running = true;
    }
    onIntervalChanged: root.refresh()
}
