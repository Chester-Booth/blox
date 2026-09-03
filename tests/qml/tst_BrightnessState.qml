import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "BrightnessState"

    Services.BrightnessState {
        id: state

        providerReady: true
        syncReady: true
        backendAvailable: true
        device: "amdgpu_bl1"
        backlights: ["amdgpu_bl1"]
        percent: 62
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.backendAvailable = true;
        state.device = "amdgpu_bl1";
        state.backlights = ["amdgpu_bl1"];
        state.percent = 62;
        state.blueLightMode = "auto";
        state.blueLightActive = false;
        state.ddcAvailable = false;
        state.ddcDisplayCount = 0;
        state.ddcReason = "command-unavailable";
        state.busy = false;
        state.actionError = "";
    }

    function test_backlight_status_is_typed() {
        compare(state.json.percent, 62);
        compare(state.json.device, "amdgpu_bl1");
        compare(state.json.backlightCount, 1);
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
    }

    function test_many_backlights_and_ddc_are_reported() {
        state.backlights = ["amdgpu_bl1", "acpi_video0"];
        state.device = "amdgpu_bl1";
        state.ddcAvailable = true;
        state.ddcDisplayCount = 2;
        state.ddcReason = "";
        compare(state.json.backlightCount, 2);
        compare(state.json.ddcDisplayCount, 2);
        verify(state.json.ddcAvailable);
    }

    function test_missing_backlight_is_ready_but_not_actionable() {
        state.device = "";
        state.backlights = [];
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "device-unavailable");
    }

    function test_missing_backend_is_unavailable() {
        state.backendAvailable = false;
        verify(!state.json.capability.available);
        verify(!state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "command-unavailable");
    }

    function test_percent_is_clamped() {
        state.percent = 140;
        compare(state.json.percent, 100);
        state.percent = -4;
        compare(state.json.percent, 0);
    }
}
