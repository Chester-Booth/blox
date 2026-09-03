import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "TouchpadStatus"

    Services.TouchpadStatus {
        id: status

        providerSource: "file:/nonexistent/blox-touchpad-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-touchpad-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_loaded_provider_can_toggle_touchpad() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeTouchpadProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.device, "fake-touchpad");
        verify(status.json.capability.canChange);
        verify(status.toggle());
        compare(status.json.enabled, false);
        compare(status.json.providerRevision, 2);
    }
}
