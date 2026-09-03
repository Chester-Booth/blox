import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "BluetoothStatus"

    Services.BluetoothStatus {
        id: status

        providerSource: "file:/nonexistent/blox-bluetooth-provider.qml"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-bluetooth-provider.qml";
    }

    function test_optional_provider_failure_is_typed() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_action_uses_the_loaded_provider() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeBluetoothProvider.qml");
        tryCompare(status, "providerReady", true);
        const result = status.action("set-enabled", "on");
        verify(result.ok);
        compare(result.code, "ok");
        compare(result.data.operation, "set-enabled");
        compare(result.data.value, "on");
        compare(result.data.beforeRevision, 1);
        compare(result.data.afterRevision, 2);
        verify(!result.data.pending);
    }
}
