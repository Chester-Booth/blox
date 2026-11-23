import QtQuick
QtObject {
    id: root
    property string scriptRoot: ""
    property int interval: 0
    property int revision: 1
    property real lastUpdatedMs: 1000
    property bool ok: true
    property string lastError: ""
    property bool busy: false
    readonly property var json: ({schemaVersion: 1, providerRevision: root.revision, observedAtMs: root.lastUpdatedMs,
        stale: false, busy: root.busy, errorCode: null, volume: 42, muted: false, micCanChange: true,
        wifiEnabled: false, enabled: false, mode: "hybrid", supportedModes: ["hybrid", "dedicated"],
        monitors: [{name: "panel", canChange: true, refreshId: "60", rates: [{id: "60"}, {id: "144"}]}],
        capability: {available: true, ready: true, canChange: true, permission: "not-required", reason: null}})
    function refresh() {}
    // Acceptance changes only busy and the observation revision. Hardware remains unchanged.
    function accept() { root.busy = true; root.revision += 1; return true; }
    function setVolume(value) { return accept(); }
    function toggleMute() { return accept(); }
    function setMicMuted(value) { return accept(); }
    function setWifiEnabled(value) { return accept(); }
    function setBluetoothEnabled(value) { return accept(); }
    function setMode(value) { return accept(); }
    function setRefresh(monitor, rate) { return accept(); }
}
