import "../../shell/services" as Services
import QtQuick
import Quickshell
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

    SignalSpy { id: microphoneFeedback; target: status; signalName: "microphoneFeedbackRequested" }

    function init() {
        microphoneFeedback.clear();
        Quickshell.detachedCalls = [];
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
    function test_osd_delta_and_microphone_toggle_use_same_owner() {
        status.providerSource = Qt.resolvedUrl("fixtures/FakeAudioProvider.qml");
        tryCompare(status, "providerReady", true);
        let reply = status.action("adjust-volume", "5");
        verify(reply.ok);
        compare(reply.data.value, 47);
        compare(reply.data.beforeRevision, 1);
        compare(reply.data.afterRevision, 2);
        reply = status.action("adjust-volume", "999");
        compare(reply.code, "invalid-data");
        compare(status.revision, 2);
        reply = status.action("toggle-mic", "");
        verify(reply.ok);
        compare(reply.data.value, "muted");
        compare(status.json.micMuted, true);
        compare(microphoneFeedback.count, 1);
        reply = status.action("toggle-mic", "");
        verify(reply.ok);
        compare(status.json.micMuted, false);
        compare(microphoneFeedback.count, 2);
        compare(Quickshell.detachedCalls.length, 2);
        compare(Quickshell.detachedCalls[0][1], "true");
        compare(Quickshell.detachedCalls[1][1], "false");
    }

}
