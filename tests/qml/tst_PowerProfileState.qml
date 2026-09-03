import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PowerProfileState"

    Services.PowerProfileState {
        id: state

        providerReady: true
        syncReady: true
        profileServiceAvailable: true
        profile: "balanced"
    }

    function init() {
        state.providerReady = true;
        state.syncReady = true;
        state.profileServiceAvailable = true;
        state.onBattery = false;
        state.profile = "balanced";
        state.degradationReason = "none";
        state.busy = false;
        state.actionError = "";
    }

    function test_profile_is_ready_and_actionable_when_service_exists() {
        compare(state.json.profile, "balanced");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(state.json.capability.canChange);
        compare(state.json.capability.reason, null);
    }

    function test_missing_profile_daemon_is_ready_but_not_actionable() {
        state.profileServiceAvailable = false;
        compare(state.json.profile, "balanced");
        verify(state.json.capability.available);
        verify(state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "profile-unavailable");
    }

    function test_loading_is_stale_and_not_actionable() {
        state.syncReady = false;
        verify(state.json.capability.available);
        verify(!state.json.capability.ready);
        verify(!state.json.capability.canChange);
        compare(state.json.capability.reason, "provider-loading");
    }

    function test_profile_and_degradation_are_typed() {
        state.profile = "power-saver";
        state.onBattery = true;
        state.degradationReason = "high-power";
        compare(state.json.profile, "power-saver");
        verify(state.json.onBattery);
        compare(state.json.degradationReason, "high-power");
    }
}
