import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    name: "MonitorStatus"

    Services.MonitorStatus {
        id: status
        providerSource: "file:/nonexistent/blox-monitor-provider.qml"
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-monitor-provider.qml";
    }

    function test_missing_provider_is_typed() {
        tryCompare(status, "providerFailed", true);
        compare(status.json.capability.reason, "provider-unavailable");
    }

    function test_refresh_action_uses_monitor_owner() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeMonitorProvider.qml");
        tryCompare(status, "providerReady", true);
        const reply = status.action("set-refresh", "panel", "144");
        verify(reply.ok);
        verify(reply.data.pending);
        compare(status.json.monitors[0].refreshId, "144");
    }

    function test_provider_load_queries_before_the_popout_opens() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeMonitorProvider.qml");
        tryCompare(status, "providerReady", true);
        compare(status.json.providerRevision, 2);
    }

    function test_unavailable_rate_never_starts_action() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeMonitorProvider.qml");
        tryCompare(status, "providerReady", true);
        const reply = status.action("set-refresh", "panel", "75");
        verify(!reply.ok);
        compare(reply.code, "invalid-data");
    }
}
