import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "AudioStatus"

    Services.AudioStatus {
        id: status

        providerSource: "file:/nonexistent/blox-pipewire-audio-provider.qml"
        scriptRoot: "/nonexistent/scripts"
        interval: 60000
    }

    function init() {
        status.providerSource = "file:/nonexistent/blox-pipewire-audio-provider.qml";
    }

    function test_optional_provider_failure_keeps_status_owner_alive() {
        tryCompare(status, "providerFailed", true);
        verify(!status.providerReady);
        verify(status.ok);
        verify(!status.json.capability.available);
        verify(!status.json.capability.ready);
        verify(!status.json.capability.canChange);
        compare(status.json.capability.reason, "provider-unavailable");
        status.refresh();
        verify(!status.providerReady);
    }

    function test_action_reports_provider_revision_window() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeAudioProvider.qml");
        tryCompare(status, "providerReady", true);
        const result = status.action("set-volume", "47");
        verify(result.ok);
        compare(result.code, "ok");
        compare(result.data.operation, "set-volume");
        compare(result.data.value, 47);
        compare(result.data.beforeRevision, 1);
        compare(result.data.afterRevision, 2);
        compare(result.data.observedAtMs, 1001);
        verify(!result.data.pending);
    }
}
