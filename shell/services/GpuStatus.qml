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
    readonly property bool confirmationRequired: providerReady && providerLoader.item.confirmationRequired === true
    readonly property string requestedMode: providerReady ? String(providerLoader.item.requestedMode || "") : ""
    readonly property var activeClients: providerReady && Array.isArray(providerLoader.item.activeClients) ? providerLoader.item.activeClients : []
    readonly property var loadingStatus: ({
        "devices": [],
        "deviceCount": 0,
        "discreteCount": 0,
        "integratedCount": 0,
        "backend": "",
        "controller": "",
        "controllerMode": "",
        "mode": "unavailable",
        "label": "GPU loading",
        "gpuOn": false,
        "gpuUtil": "",
        "gpuTemp": "",
        "vramUsed": "",
        "vramTotal": "",
        "controlReason": "provider-loading",
        "supportedModes": [],
        "pendingMode": null,
        "pendingAction": null,
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
        "integratedCount": 0,
        "backend": "",
        "controller": "",
        "controllerMode": "",
        "mode": "unavailable",
        "label": "GPU unavailable",
        "gpuOn": false,
        "gpuUtil": "",
        "gpuTemp": "",
        "vramUsed": "",
        "vramTotal": "",
        "controlReason": "provider-unavailable",
        "supportedModes": [],
        "pendingMode": null,
        "pendingAction": null,
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

    function setMode(value, logoutAfterAcceptance) {
        return root.providerReady && providerLoader.item.setMode(value, logoutAfterAcceptance);
    }

    function requestMode(value) {
        return root.providerReady && providerLoader.item.requestMode(value);
    }

    function cancelModeRequest() {
        if (root.providerReady)
            providerLoader.item.cancelModeRequest();
    }

    function confirmModeRequest() {
        return root.providerReady && providerLoader.item.confirmModeRequest();
    }

    function actionResult(ok, code, message, data) {
        return {"version": 1, "ok": ok, "code": code, "message": message, "data": data};
    }

    function action(operation, value) {
        if (operation !== "set-mode")
            return actionResult(false, "invalid-data", "unknown GPU operation", null);
        if (!root.providerReady || !root.json.capability || root.json.capability.canChange !== true)
            return actionResult(false, "unavailable", "GPU mode control is unavailable", null);
        if (root.json.stale === true)
            return actionResult(false, "stale", "GPU state is stale", null);
        if (root.json.busy === true)
            return actionResult(false, "busy", "a GPU mode change is already in progress", null);
        const mode = String(value || "");
        if (!Array.isArray(root.json.supportedModes) || root.json.supportedModes.indexOf(mode) < 0)
            return actionResult(false, "invalid-data", "the requested GPU mode is unsupported", null);
        const beforeRevision = Number(root.json.providerRevision || 0);
        if (!root.setMode(mode))
            return actionResult(false, "failed", "the GPU controller rejected the request", null);
        return actionResult(true, "ok", "", {"operation": operation, "mode": mode, "beforeRevision": beforeRevision, "afterRevision": beforeRevision, "pending": true, "pendingAction": root.json.pendingAction || null});
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
