import QtQuick
import Quickshell

// Guard the optional Bluetooth plugin and expose one typed owner for status
// reads and adapter power actions.
Scope {
    id: root

    property int interval: 30000
    property url providerSource: Qt.resolvedUrl("BluezProvider.qml")
    property var json: providerReady ? providerLoader.item.json : providerFailed ? unavailableStatus : loadingStatus
    property bool ok: true
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? String(providerLoader.item.lastError || "") : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error

    readonly property var loadingStatus: ({
        "icon": "󰂯",
        "class": "loading",
        "summary": "Bluetooth loading",
        "details": "Waiting for BlueZ",
        "tooltip": "Bluetooth loading",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-loading",
        "enabled": false,
        "capability": {
            "available": true,
            "ready": false,
            "canChange": false,
            "permission": "unknown",
            "reason": "provider-loading"
        }
    })

    readonly property var unavailableStatus: ({
        "icon": "󰂯",
        "class": "unavailable",
        "summary": "Bluetooth unavailable",
        "details": "Bluetooth provider unavailable",
        "tooltip": "Bluetooth unavailable",
        "schemaVersion": 1,
        "providerRevision": 0,
        "observedAtMs": 0,
        "stale": true,
        "busy": false,
        "errorCode": "provider-unavailable",
        "enabled": false,
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

    function setBluetoothEnabled(value) {
        return root.providerReady && providerLoader.item.setBluetoothEnabled(value);
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
        return {
            "operation": operation,
            "value": value,
            "beforeRevision": beforeRevision,
            "afterRevision": afterRevision,
            "observedAtMs": Number(status.observedAtMs || 0),
            "pending": afterRevision < beforeRevision + 1
        };
    }

    function action(operation, value) {
        const name = String(operation || "");
        if (["set-enabled", "toggle-enabled"].indexOf(name) < 0)
            return root.actionResult(false, "invalid-data", "unknown Bluetooth operation", null);
        if (!root.providerReady)
            return root.actionResult(false, "unavailable", "the BlueZ provider is not ready", null);
        const status = root.json || ({ });
        const capability = status.capability || ({ });
        const beforeRevision = Number(status.providerRevision || 0);
        if (status.busy === true)
            return root.actionResult(false, "busy", "a Bluetooth action is already in progress", null);
        if (capability.canChange !== true)
            return root.actionResult(false, capability.reason === "permission-denied" ? "permission-denied" : "unavailable", "the Bluetooth adapter is unavailable", null);
        let enabled;
        if (name === "set-enabled") {
            if (["on", "off"].indexOf(String(value || "")) < 0)
                return root.actionResult(false, "invalid-data", "Bluetooth state must be on or off", null);
            enabled = String(value) === "on";
        } else {
            enabled = status.enabled !== true;
        }
        if (!root.setBluetoothEnabled(enabled))
            return root.actionResult(false, "failed", "the Bluetooth action was rejected", null);
        return root.actionResult(true, "ok", "", root.actionData(name, enabled ? "on" : "off", beforeRevision));
    }

    Loader {
        id: providerLoader

        active: true
        source: root.providerSource
        onLoaded: item.interval = root.interval
    }

    onIntervalChanged: root.refresh()
}
