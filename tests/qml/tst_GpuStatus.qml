import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "GpuStatus"

    Services.GpuStatus {
        id: status

        providerSource: "file:/nonexistent/blox-gpu-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-gpu-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_loaded_provider_exposes_detection_and_control() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeGpuProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.deviceCount, 1);
        verify(status.json.capability.canChange);
        verify(status.setMode("performance"));
        compare(status.json.mode, "performance");
        compare(status.json.providerRevision, 2);
    }
}
