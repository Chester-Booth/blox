import QtQuick
import Quickshell

// Guard optional graphics discovery and expose a typed status to the bar and
// performance popout.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property url providerSource: Qt.resolvedUrl("GpuProvider.qml")
    property var json: ({ })
    property bool ok: providerReady ? providerLoader.item.ok : !providerFailed
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? String(providerLoader.item.lastError || "") : providerFailed ? "provider-unavailable" : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error
    readonly property var loadingStatus: ({
        "devices": [],
        "deviceCount": 0,
        "discreteCount": 0,
        "backend": "",
        "mode": "unavailable",
        "label": "GPU loading",
        "gpuOn": false,
        "gpuUtil": "",
        "gpuTemp": "",
        "vramUsed": "",
        "vramTotal": "",
        "controlReason": "provider-loading",
        "tooltip": "Waiting for graphics discovery",
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
        "devices": [],
        "deviceCount": 0,
        "discreteCount": 0,
        "backend": "",
        "mode": "unavailable",
        "label": "GPU unavailable",
        "gpuOn": false,
        "gpuUtil": "",
        "gpuTemp": "",
        "vramUsed": "",
        "vramTotal": "",
        "controlReason": "provider-unavailable",
        "tooltip": "GPU provider unavailable",
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

    function setMode(value) {
        return root.providerReady && providerLoader.item.setMode(value);
    }

    Loader {
        id: providerLoader

        active: true
        source: root.providerSource
        onLoaded: {
            item.scriptRoot = root.scriptRoot;
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

    onScriptRootChanged: {
        if (root.providerReady)
            providerLoader.item.scriptRoot = root.scriptRoot;
    }
    onIntervalChanged: root.refresh()
    onProviderReadyChanged: root.syncJson()
    onProviderFailedChanged: root.syncJson()
    onProviderSourceChanged: root.syncJson()
    Component.onCompleted: root.syncJson()
}
