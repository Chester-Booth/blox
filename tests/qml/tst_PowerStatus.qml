import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "PowerStatus"

    Services.PowerStatus {
        id: status

        providerSource: "file:/nonexistent/blox-upower-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-upower-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
        status.refresh();
        verify(!status.providerReady);
    }

    function test_loaded_provider_keeps_status_owner_alive() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakePowerProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.status, "Discharging");
        compare(status.json.capacity, 72);
        compare(status.json.providerRevision, 4);
        status.refresh();
        compare(status.json.timeLabel, "2h 5m left");
    }
}
