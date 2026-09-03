import "../../shell/services" as Services
import QtQuick
import QtTest

TestCase {
    id: testCase
    name: "AudioState"

    QtObject {
        id: sinkAudio

        property real volume: 0.72
        property bool muted: false
    }

    QtObject {
        id: sourceAudio

        property real volume: 1
        property bool muted: false
    }

    QtObject {
        id: sink

        property bool ready: true
        property string description: "Test sink"
        property string name: "test-sink"
        property QtObject audio: sinkAudio
    }

    QtObject {
        id: source

        property bool ready: true
        property string description: "Test source"
        property string name: "test-source"
        property QtObject audio: sourceAudio
    }

    QtObject {
        id: service

        property bool ready: true
    }

    Services.AudioState {
        id: provider

        providerReady: service.ready
        sink: sink
        source: source
    }

    function init() {
        service.ready = true;
        sink.ready = true;
        source.ready = true;
        sinkAudio.volume = 0.72;
        sinkAudio.muted = false;
        sourceAudio.muted = false;
    }

    function test_status_has_freshness_metadata() {
        verify(provider.json.schemaVersion === 1);
        verify(provider.json.providerRevision > 0);
        verify(provider.json.observedAtMs > 0);
        verify(!provider.json.stale);
    }

    function test_service_loss_is_unready_and_actions_are_blocked() {
        verify(provider.json.capability.ready);
        compare(provider.json.volume, 72);
        const previousRevision = provider.json.providerRevision;
        service.ready = false;
        tryVerify(() => provider.json.capability.ready === false);
        compare(provider.json.capability.reason, "provider-not-ready");
        verify(provider.json.providerRevision > previousRevision);
        verify(provider.json.stale);
        verify(!provider.setVolume(50));
    }

    function test_service_reappearance_restores_state_and_actions() {
        service.ready = false;
        service.ready = true;
        tryVerify(() => provider.json.capability.ready === true);
        compare(provider.json.volume, 72);
        verify(provider.json.providerRevision > 0);
        verify(!provider.json.stale);
        verify(provider.setVolume(50));
        compare(sinkAudio.volume, 0.5);
        verify(provider.json.providerRevision > 0);
    }

    function test_missing_sink_and_source_are_unavailable_without_actions() {
        provider.sink = null;
        provider.source = null;
        tryVerify(() => provider.json.capability.reason === "no-default-sink");
        verify(provider.json.capability.available);
        verify(provider.json.capability.ready);
        verify(!provider.json.capability.canChange);
        verify(!provider.json.micCanChange);
        compare(provider.json.volume, 0);
        verify(provider.json.muted);
        verify(provider.json.micMuted);
        verify(!provider.setVolume(50));
        verify(!provider.setMicMuted(false));
        provider.sink = sink;
        provider.source = source;
        tryVerify(() => provider.json.micCanChange);
    }
}
