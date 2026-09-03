import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PowerProfileStatus"

    Services.PowerProfileStatus {
        id: status

        providerSource: "file:/nonexistent/blox-power-profile-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-power-profile-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_loaded_provider_can_change_profile() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakePowerProfileProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.profile, "balanced");
        verify(status.json.capability.canChange);
        verify(status.setProfile("power-saver"));
        compare(status.json.profile, "power-saver");
        compare(status.json.providerRevision, 2);
    }
}
