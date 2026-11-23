import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    name: "PowerProfilePolicy"
    QtObject {
        id: provider
        property var calls: []
        property bool succeeds: true
        function setProfile(id) { calls = calls.concat([id]); return succeeds; }
    }
    Services.PowerProfilePolicy {
        id: policy
        provider: provider
    }
    function init() {
        policy.canChange = false;
        policy.policy = null;
        policy.onBattery = false;
        policy.currentProfile = "balanced";
        policy.busy = false;
        policy.reset();
        provider.calls = [];
        provider.succeeds = true;
    }
    function test_policy_source_and_manual_override() {
        policy.policy = {acProfile: "performance", batteryProfile: "power-saver"};
        policy.canChange = true;
        compare(provider.calls.join(","), "performance");
        verify(policy.setManualProfile("balanced"));
        verify(policy.manualOverride);
        policy.reconcile();
        compare(provider.calls.join(","), "performance,balanced");
        policy.onBattery = true;
        verify(!policy.manualOverride);
        compare(provider.calls.join(","), "performance,balanced,power-saver");
    }
    function test_unavailable_and_unset_policy_do_nothing() {
        policy.policy = {acProfile: "performance", batteryProfile: null};
        compare(provider.calls.length, 0);
        policy.onBattery = true;
        policy.canChange = true;
        compare(provider.calls.length, 0);
    }
    function test_refresh_preserves_manual_override_until_policy_changes() {
        policy.policy = {acProfile: "performance", batteryProfile: "power-saver"};
        policy.canChange = true;
        verify(policy.setManualProfile("balanced"));
        provider.calls = [];
        policy.policy = {acProfile: "performance", batteryProfile: "power-saver"};
        verify(policy.manualOverride);
        compare(provider.calls.length, 0);
        policy.policy = {acProfile: "balanced", batteryProfile: "power-saver"};
        verify(!policy.manualOverride);
    }
    function test_failed_policy_does_not_retry_forever() {
        provider.succeeds = false;
        policy.policy = {acProfile: "performance", batteryProfile: "power-saver"};
        policy.canChange = true;
        policy.reconcile();
        compare(provider.calls.length, 1);
        verify(!policy.setManualProfile("balanced"));
        verify(!policy.manualOverride);
        policy.policy = {acProfile: "power-saver", batteryProfile: "balanced"};
        compare(provider.calls[provider.calls.length - 1], "power-saver");
    }
}
