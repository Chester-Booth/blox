import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "VendorPerformanceStatus"

    Services.VendorPerformanceStatus {
        id: status

        providerSource: "file:/nonexistent/blox-vendor-performance-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-vendor-performance-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_loaded_provider_can_change_profile() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeVendorPerformanceProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.profile, "quiet");
        verify(status.json.capability.canChange);
        verify(status.setProfile("performance"));
        compare(status.json.profile, "performance");
        compare(status.json.providerRevision, 2);
    }
}
