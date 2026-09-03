import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "TouchpadState"

    Services.TouchpadState {
        id: state

        providerReady: true
        syncReady: true
        backendAvailable: true
        devices: ["fake-touchpad"]
        device: "fake-touchpad"
        touchpadEnabled: true
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.backendAvailable = true;
        state.devices = ["fake-touchpad"];
        state.device = "fake-touchpad";
        state.touchpadEnabled = true;
        state.busy = false;
        state.actionError = "";
    }

    function test_discovered_touchpad_is_actionable() {
        compare(state.json.device, "fake-touchpad");
        compare(state.json.touchpadCount, 1);
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
    }

    function test_missing_device_is_ready_but_not_actionable() {
        state.devices = [];
        state.device = "";
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "device-unavailable");
    }

    function test_backend_loss_is_unavailable() {
        state.backendAvailable = false;
        verify(!state.json.capability.available);
        verify(!state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "backend-unavailable");
    }
}
