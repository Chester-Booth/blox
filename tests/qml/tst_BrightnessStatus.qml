import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "BrightnessStatus"

    Services.BrightnessStatus {
        id: status

        providerSource: "file:/nonexistent/blox-brightness-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-brightness-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_loaded_provider_reads_and_changes_brightness() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeBrightnessProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.percent, 62);
        verify(status.json.capability.canChange);
        verify(status.setBrightness(71));
        compare(status.json.percent, 71);
        compare(status.json.providerRevision, 2);
    }
}
