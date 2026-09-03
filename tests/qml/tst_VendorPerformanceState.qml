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
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.backendAvailable = true;
        state.vendor = "asusctl";
        state.profile = "quiet";
        state.profileLabel = "Quiet";
        state.profiles = ["quiet", "balanced", "performance"];
        state.busy = false;
        state.actionError = "";
    }

    function test_vendor_profile_is_typed_and_actionable() {
        compare(state.json.vendor, "asusctl");
        compare(state.json.profile, "quiet");
        verify(state.json.capability.canChange);
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
}
