import qs.shared
import QtQuick
import "ActionContract.js" as ActionContract
import Quickshell

// Guard the optional Networking plugin so a missing backend cannot stop the
// shell. The same object owns status reads and CLI/UI actions.
Scope {
    id: root

    property int interval: 30000
    property url providerSource: Qt.resolvedUrl("NetworkManagerProvider.qml")
    readonly property bool nativeProvider: root.providerSource === Qt.resolvedUrl("NetworkManagerProvider.qml")
    property bool nativeActivated: false
    property var json: providerReady ? providerLoader.item.json : providerFailed ? unavailableStatus : loadingStatus
    property bool ok: true
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? String(providerLoader.item.lastError || "") : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error || (root.nativeProvider && !root.nativeActivated && availability.ready && !availability.available)

    readonly property var loadingStatus: ({
        "icon": "󰤩",
        "class": "loading",
        "summary": "Network loading",
        "details": "Waiting for NetworkManager",
        "tooltip": "Network loading",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-loading",
        "wifiEnabled": false,
        "capability": {
            "available": true,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "provider-loading"
        }
    })

    readonly property var unavailableStatus: ({
        "icon": "󰤩",
        "class": "unavailable",
        "summary": "Network unavailable",
        "details": "Network provider unavailable",
        "tooltip": "Network unavailable",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-unavailable",
        "wifiEnabled": false,
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

    function setWifiEnabled(value) {
        return root.providerReady && providerLoader.item.setWifiEnabled(value);
    }

    function actionResult(ok, code, message, data) {
        return {
            "version": 1,
            "ok": ok,
            "code": code,
            "message": message,
            "data": data
        };
    }

    function actionData(operation, value, beforeRevision) {
        const status = root.json || ({ });
        const afterRevision = Number(status.providerRevision || beforeRevision);
        const data = {
            "operation": operation,
            "beforeRevision": beforeRevision,
            "afterRevision": afterRevision,
            "observedAtMs": Number(status.observedAtMs || 0),
            "pending": status.busy === true || status.wifiEnabled !== (value === "on")
        };
        if (value !== undefined)
            data.value = value;
        return data;
    }

    function action(operation, value) {
        const name = String(operation || "");
        if (["set-wifi", "toggle-wifi"].indexOf(name) < 0)
            return root.actionResult(false, "invalid-data", "unknown network operation", null);
        if (!root.providerReady)
            return root.actionResult(false, "unavailable", "the NetworkManager provider is not ready", null);
        const status = root.json || ({ });
        const capability = status.capability || ({ });
        const beforeRevision = Number(status.providerRevision || 0);
        const blocked = ActionContract.blockedCode(status, capability.canChange);
        if (blocked)
            return root.actionResult(false, blocked, "the network action is unavailable", null);
        let enabled;
        if (name === "set-wifi") {
            if (["on", "off"].indexOf(String(value || "")) < 0)
                return root.actionResult(false, "invalid-data", "Wi-Fi state must be on or off", null);
            enabled = String(value) === "on";
        } else {
            enabled = status.wifiEnabled !== true;
        }
        if (!root.setWifiEnabled(enabled))
            return root.actionResult(false, "failed", "the Wi-Fi action was rejected", null);
        return root.actionResult(true, "ok", "", root.actionData(name, enabled ? "on" : "off", beforeRevision));
    }

    NativeServiceAvailability {
        id: availability
        service: "org.freedesktop.NetworkManager"
        enabled: root.nativeProvider && !root.nativeActivated
        onServiceFound: { if (root.nativeProvider) root.nativeActivated = true; }
    }

    Loader {
        id: providerLoader

        active: !root.nativeProvider || root.nativeActivated
        source: root.providerSource
        onLoaded: item.interval = root.interval
    }

    onIntervalChanged: root.refresh()
}
