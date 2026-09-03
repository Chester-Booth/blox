import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "GpuState"

    Services.GpuState {
        id: state

        providerReady: true
        syncReady: true
        backendAvailable: true
        devices: [{"id": "card0", "vendor": "amd"}]
        deviceCount: 1
        mode: "eco"
        label: "AMD graphics"
        controlAvailable: false
        controlReason: "no-supported-controller"
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.backendAvailable = true;
        state.devices = [{"id": "card0", "vendor": "amd"}];
        state.deviceCount = 1;
        state.discreteCount = 0;
        state.backend = "drm";
        state.mode = "eco";
        state.label = "AMD graphics";
        state.gpuOn = false;
        state.controlReason = "no-supported-controller";
        state.permission = "not-required";
        state.controlAvailable = false;
        state.busy = false;
        state.actionError = "";
    }

    function test_gpu_detection_can_be_ready_without_a_control() {
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "no-supported-controller");
        compare(state.json.deviceCount, 1);
    }

    function test_missing_gpu_is_typed_empty() {
        state.devices = [];
        state.deviceCount = 0;
        state.controlReason = "no-gpu";
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "no-gpu");
    }

    function test_privileged_control_is_denied() {
        state.permission = "denied";
        state.controlReason = "privileged-control";
        verify(!state.json.capability.canChange);
        compare(state.json.capability.permission, "denied");
        compare(state.json.capability.reason, "privileged-control");
    }
}
