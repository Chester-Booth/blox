import qs.shared
import QtQuick
import "ActionContract.js" as ActionContract
import Quickshell

// Keep the script-backed display owner behind the same typed optional-provider
// boundary as the native service adapters.
Scope {
    id: root

    property string scriptRoot: ""
    signal brightnessApplied(int percent)
    property int interval: 30000
    property url providerSource: Qt.resolvedUrl("BrightnessProvider.qml")
    property var json: ({
    })
    property bool ok: providerReady ? providerLoader.item.ok : !providerFailed
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? String(providerLoader.item.lastError || "") : providerFailed ? "provider-unavailable" : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error
    readonly property var loadingStatus: ({
        "icon": "󰃠",
        "percent": 0,
        "blueLightMode": "auto",
        "blueLightActive": false,
        "device": "",
        "backlightCount": 0,
        "backlights": [],
        "ddcAvailable": false,
        "ddcDisplayCount": 0,
        "ddcReason": "command-unavailable",
        "details": "Waiting for brightness provider",
        "tooltip": "Waiting for brightness provider",
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
        "icon": "󰃠",
        "percent": 0,
        "blueLightMode": "auto",
        "blueLightActive": false,
        "device": "",
        "backlightCount": 0,
        "backlights": [],
        "ddcAvailable": false,
        "ddcDisplayCount": 0,
        "ddcReason": "command-unavailable",
        "details": "Brightness provider unavailable",
        "tooltip": "Brightness provider unavailable",
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

    function setBrightness(value) {
        return root.providerReady && providerLoader.item.setBrightness(value);
    }

    function action(operation, value) {
        const status = root.json || {};
        // This provider keeps one replaceable target, so repeats can accumulate
        // while its current write finishes. Other busy providers still deny.
        const queued = root.providerReady && providerLoader.item.actionBusy === true
            && providerLoader.item.pendingBrightness !== undefined
            && providerLoader.item.pendingBrightness.length > 0;
        const blocked = ActionContract.blockedCode(queued ? Object.assign({}, status, {busy: false}) : status,
            status.capability && status.capability.canChange);
        if (blocked)
            return ActionContract.result(false, blocked, "the action is unavailable");
        const beforeRevision = Number(status.providerRevision || 0);
        if (["set", "adjust"].indexOf(operation) < 0)
            return ActionContract.result(false, "invalid-data", "unknown brightness operation");
        const requested = Number(value);
        if (!isFinite(requested) || Math.round(requested) !== requested)
            return ActionContract.result(false, "invalid-data", "brightness must be an integer");
        const base = root.providerReady && providerLoader.item.adjustmentBase !== undefined
            ? Number(providerLoader.item.adjustmentBase) : Number(status.percent || 0);
        const target = operation === "adjust" ? Math.max(0, Math.min(100, base + requested)) : requested;
        if (target < 0 || target > 100)
            return ActionContract.result(false, "invalid-data", "brightness must be from 0 to 100");
        const accepted = root.setBrightness(target);
        value = target;
        if (!accepted)
            return ActionContract.result(false, "failed", "the provider rejected the action");
        return ActionContract.accepted(operation, value, root.json || {}, beforeRevision);
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
        function onBrightnessApplied(percent) { root.brightnessApplied(percent); }
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
