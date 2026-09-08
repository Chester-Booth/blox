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
        compare(status.json.deviceCount, 2);
        verify(status.json.capability.canChange);
        verify(status.setMode("dedicated"));
        compare(status.json.mode, "dedicated");
        compare(status.json.providerRevision, 2);
    }

    function test_pending_logout_remains_typed_after_action_acceptance() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeGpuProvider.qml");
        tryCompare(status, "providerReady", true);
        const reply = status.action("set-mode", "integrated");
        verify(reply.ok);
        tryCompare(status.json, "pendingMode", "integrated");
        compare(status.json.pendingAction, "logout");
        compare(status.json.mode, "hybrid");
    }

    function test_integrated_request_confirms_active_gpu_clients() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeGpuProvider.qml");
        tryCompare(status, "providerReady", true);
        verify(status.requestMode("integrated"));
        verify(status.confirmationRequired);
        compare(status.activeClients.length, 1);
        compare(status.json.pendingMode, null);
        verify(status.confirmModeRequest());
        verify(!status.confirmationRequired);
        compare(status.json.pendingMode, "integrated");
        compare(status.json.pendingAction, "logout");
    }

    function test_non_integrated_request_confirms_logout_without_gpu_clients() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeGpuProvider.qml");
        tryCompare(status, "providerReady", true);
        verify(status.requestMode("dedicated"));
        verify(status.confirmationRequired);
        compare(status.requestedMode, "dedicated");
        compare(status.activeClients.length, 0);
        verify(status.confirmModeRequest());
        compare(status.json.pendingMode, "dedicated");
        compare(status.json.pendingAction, "logout");
    }
}
