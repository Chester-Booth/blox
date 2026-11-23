import qs.shared
import QtQuick
import "ActionContract.js" as ActionContract
import Quickshell

// Guard the Hyprland monitor owner and keep its absence non-fatal.
Scope {
    id: root

    property string scriptRoot: ""
    property int interval: 60000
    property url providerSource: Qt.resolvedUrl("MonitorProvider.qml")
    property var json: providerReady ? providerLoader.item.json : providerFailed ? unavailableStatus : loadingStatus
    property bool ok: providerReady ? providerLoader.item.ok : !providerFailed
    property real lastUpdatedMs: providerReady ? providerLoader.item.lastUpdatedMs : 0
    property string lastError: providerReady ? providerLoader.item.lastError : providerFailed ? "provider-unavailable" : ""
    readonly property int revision: providerReady ? providerLoader.item.revision : 0
    readonly property bool providerReady: providerLoader.status === Loader.Ready && providerLoader.item !== null
    readonly property bool providerFailed: providerLoader.status === Loader.Error
    readonly property var loadingStatus: emptyStatus("provider-loading", true)
    readonly property var unavailableStatus: emptyStatus("provider-unavailable", false)

    function emptyStatus(reason, available) {
        return {
            "schemaVersion": 1, "providerRevision": 0, "observedAtMs": 0,
            "stale": true, "busy": false, "errorCode": reason,
            "monitors": [], "monitorCount": 0,
            "capability": {"available": available, "ready": false, "canChange": false, "permission": "unknown", "reason": reason}
        };
    }

    function refresh() {
        return root.providerReady && providerLoader.item.refresh();
    }

    function setRefresh(monitor, rate) {
        return root.providerReady && providerLoader.item.setRefresh(monitor, rate);
    }

    function actionResult(ok, code, message, data) {
        return {"version": 1, "ok": ok, "code": code, "message": message, "data": data};
    }

    function action(operation, monitor, rate) {
        if (operation !== "set-refresh")
            return actionResult(false, "invalid-data", "unknown monitor operation", null);
        if (!root.providerReady)
            return actionResult(false, "unavailable", "refresh control is unavailable", null);
        const blocked = ActionContract.blockedCode(root.json, root.json.capability && root.json.capability.canChange);
        if (blocked)
            return actionResult(false, blocked, "refresh control is unavailable", null);
        const choice = (root.json.monitors || []).find(item => item.name === monitor);
        if (!choice || choice.canChange !== true || !(choice.rates || []).some(item => String(item.id) === String(rate)))
            return actionResult(false, "invalid-data", "the monitor or refresh rate is unavailable", null);
        const beforeRevision = Number(root.json.providerRevision || 0);
        if (!root.setRefresh(monitor, rate))
            return actionResult(false, "failed", "the monitor action was rejected", null);
        const after = root.json || ({});
        const observed = (after.monitors || []).find(item => item.name === monitor);
        return actionResult(true, "ok", "", {"operation": operation, "monitor": monitor, "refreshId": rate,
            "beforeRevision": beforeRevision, "afterRevision": Number(after.providerRevision || beforeRevision),
            "observedAtMs": Number(after.observedAtMs || 0),
            "pending": after.busy === true || !observed || String(observed.refreshId) !== String(rate)});
    }

    Loader {
        id: providerLoader
        active: true
        source: root.providerSource
        onLoaded: {
            item.scriptRoot = root.scriptRoot;
            item.interval = root.interval;
            item.refresh();
        }
    }

    onScriptRootChanged: if (root.providerReady) providerLoader.item.scriptRoot = root.scriptRoot
    onIntervalChanged: if (root.providerReady) providerLoader.item.interval = root.interval
}
