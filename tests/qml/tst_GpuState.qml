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
        state.integratedCount = 1;
        state.backend = "drm";
        state.mode = "eco";
        state.label = "AMD graphics";
        state.gpuOn = false;
        state.controlReason = "no-supported-controller";
        state.permission = "not-required";
        state.controlAvailable = false;
        state.supportedModes = [];
        state.pendingMode = null;
        state.pendingAction = null;
        state.busy = false;
        state.actionError = "";
    }

    function test_gpu_detection_can_be_ready_without_a_control() {
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "no-switchable-gpu");
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
        state.devices = [{"kind": "integrated"}, {"kind": "discrete"}];
        state.deviceCount = 2;
        state.integratedCount = 1;
        state.discreteCount = 1;
        state.permission = "denied";
        state.controlReason = "privileged-control";
        verify(!state.json.capability.canChange);
        compare(state.json.capability.permission, "denied");
        compare(state.json.capability.reason, "privileged-control");
    }

    function test_dual_gpu_requires_a_controller() {
        state.devices = [{"kind": "integrated"}, {"kind": "discrete"}];
        state.deviceCount = 2;
        state.integratedCount = 1;
        state.discreteCount = 1;
        state.controlReason = "no-supported-controller";
        compare(state.json.capability.reason, "no-supported-controller");
        verify(!state.json.capability.canChange);
    }

    function test_incompatible_controller_is_hidden() {
        state.devices = [{"kind": "integrated"}, {"kind": "discrete"}];
        state.deviceCount = 2;
        state.integratedCount = 1;
        state.discreteCount = 1;
        state.controller = "supergfxctl";
        state.mode = "hybrid";
        state.controlReason = "controller-incompatible";
        state.controlAvailable = false;
        compare(state.json.capability.reason, "controller-incompatible");
        verify(!state.json.capability.canChange);
    }

    function test_controller_modes_and_pending_logout_are_typed() {
        state.devices = [{"kind": "integrated"}, {"kind": "discrete"}];
        state.deviceCount = 2;
        state.integratedCount = 1;
        state.discreteCount = 1;
        state.controller = "supergfxctl";
        state.controllerMode = "AsusMuxDgpu";
        state.mode = "dedicated";
        state.supportedModes = ["dedicated", "hybrid", "integrated"];
        state.pendingMode = "integrated";
        state.pendingAction = "logout";
        state.controlAvailable = true;
        verify(state.json.capability.canChange);
        compare(state.json.supportedModes[0], "dedicated");
        compare(state.json.pendingAction, "logout");
    }

    function test_stale_controller_state_disables_changes() {
        state.devices = [{"kind": "integrated"}, {"kind": "discrete"}];
        state.deviceCount = 2;
        state.integratedCount = 1;
        state.discreteCount = 1;
        state.supportedModes = ["hybrid"];
        state.controlAvailable = true;
        state.syncReady = false;
        verify(state.json.stale);
        verify(!state.json.capability.canChange);
    }

    function test_removed_controller_is_typed() {
        state.devices = [{"kind": "integrated"}, {"kind": "discrete"}];
        state.deviceCount = 2;
        state.integratedCount = 1;
        state.discreteCount = 1;
        state.controlAvailable = false;
        state.controlReason = "removed";
        compare(state.json.capability.reason, "removed");
        verify(!state.json.capability.canChange);
    }
}
