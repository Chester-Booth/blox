import QtQuick
QtObject {
    property string scriptRoot: ""
    property int interval: 0
    property int revision: 1
    property real lastUpdatedMs: 1000
    property bool ok: true
    property string lastError: ""
    property var json: ({schemaVersion: 1, providerRevision: 1, observedAtMs: 1000,
        stale: false, busy: false, errorCode: null, volume: 42, micCanChange: true,
        supportedModes: ["hybrid"], monitors: [{name: "panel", canChange: true, rates: [{id: "60"}]}],
        capability: {available: true, ready: true, canChange: true, permission: "not-required", reason: null}})
    function refresh() {}
    function setVolume(value) { return false; }
    function toggleMute() { return false; }
    function setMicMuted(value) { return false; }
    function setWifiEnabled(value) { return false; }
    function setBluetoothEnabled(value) { return false; }
    function setMode(value) { return false; }
    function setRefresh(monitor, rate) { return false; }
}
