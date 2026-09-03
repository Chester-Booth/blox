import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "BluetoothState"

    Services.BluetoothState {
        id: state

        providerReady: true
        syncReady: true
        adapterAvailable: true
        adapterEnabled: true
        connectedNames: ["Headset", "Mouse"]
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.adapterAvailable = true;
        state.adapterEnabled = true;
        state.adapterBlocked = false;
        state.connectedNames = ["Headset", "Mouse"];
        state.busy = false;
        state.actionError = "";
    }

    function test_connected_devices_are_typed_without_addresses() {
        compare(state.json.class, "connected");
        compare(state.json.summary, "Headset");
        compare(state.json.details, "Connected: Headset, Mouse");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
        verify(JSON.stringify(state.json).indexOf("AA:BB:CC:DD:EE:FF") < 0);
    }

    function test_disabled_adapter_is_available_and_actionable() {
        state.adapterEnabled = false;
        state.connectedNames = [];
        compare(state.json.class, "disabled");
        compare(state.json.summary, "Bluetooth off");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
    }

    function test_missing_adapter_is_unavailable() {
        state.adapterAvailable = false;
        verify(!state.json.capability.available);
        verify(!state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "no-adapter");
    }

    function test_blocked_adapter_reports_permission_denied() {
        state.adapterBlocked = true;
        verify(state.json.capability.available);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.permission, "denied");
        compare(state.json.capability.reason, "permission-denied");
    }

    function test_loading_and_timeout_are_visible() {
        state.syncReady = false;
        verify(state.json.capability.available);
        verify(!state.json.capability.ready);
        compare(state.json.capability.reason, "provider-loading");
        state.syncReady = true;
        state.actionError = "timeout";
        state.busy = true;
        verify(state.json.busy);
        compare(state.json.errorCode, "timeout");
    }
}
