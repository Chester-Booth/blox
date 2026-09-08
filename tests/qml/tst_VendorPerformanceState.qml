import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "VendorPerformanceState"

    Services.VendorPerformanceState {
        id: state

        providerReady: true
        syncReady: true
        backendAvailable: true
        vendor: "asusctl"
        profile: "quiet"
        profileLabel: "Quiet"
        profiles: ["quiet", "balanced", "performance"]
        profileControlDomain: "platform-profile"
        fanCurveCapability: ({"available": false, "ready": true, "canChange": false, "permission": "not-required", "reason": "fan-curves-unsupported"})
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.backendAvailable = true;
        state.vendor = "asusctl";
        state.profile = "quiet";
        state.profileLabel = "Quiet";
        state.profiles = ["quiet", "balanced", "performance"];
        state.profileControlDomain = "platform-profile";
        state.fanCurveAvailable = false;
        state.fanCurveEnabled = false;
        state.fanCurveCapability = {"available": false, "ready": true, "canChange": false, "permission": "not-required", "reason": "fan-curves-unsupported"};
        state.busy = false;
        state.actionError = "";
    }

    function test_vendor_profile_is_typed_and_actionable() {
        compare(state.json.vendor, "asusctl");
        compare(state.json.profile, "quiet");
        verify(state.json.capability.canChange);
        compare(state.json.profileControlDomain, "platform-profile");
        verify(!state.json.fanCurveCapability.available);
    }

    function test_missing_vendor_backend_is_unavailable() {
        state.backendAvailable = false;
        verify(!state.json.capability.available);
        verify(!state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "backend-unavailable");
    }

    function test_empty_profile_set_is_ready_but_not_actionable() {
        state.profiles = [];
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "profile-unavailable");
    }

    function test_independent_fan_curve_capability_is_separate() {
        state.fanCurveAvailable = true;
        state.fanCurveEnabled = true;
        state.fanCurveCapability = {"available": true, "ready": true, "canChange": true, "permission": "not-required", "reason": null};
        verify(state.json.capability.canChange);
        verify(state.json.fanCurveCapability.canChange);
        verify(state.json.fanCurveEnabled);
    }
}
