import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

// Reactive PipeWire adapter. AudioState owns the testable contract while
// this component only connects it to the optional Quickshell plugin.
Scope {
    id: root

    property var pipewireService: Pipewire
    readonly property bool ok: true
    readonly property string lastError: ""
    readonly property real lastUpdatedMs: state.observedAtMs
    readonly property int revision: state.revision
    readonly property bool providerReady: state.providerReady
    readonly property var sink: state.sink
    readonly property var source: state.source
    readonly property bool sinkReady: state.sinkReady
    readonly property bool sourceReady: state.sourceReady
    readonly property bool canChange: state.canChange
    readonly property var json: state.json

    AudioState {
        id: state

        providerReady: root.pipewireService && root.pipewireService.ready === true
        sink: root.pipewireService ? root.pipewireService.defaultAudioSink : null
        source: root.pipewireService ? root.pipewireService.defaultAudioSource : null
    }

    // Binding the non-stream nodes keeps their audio properties live. Without
    // this tracker the PipeWire plugin can report the nodes but not their
    // volume or mute properties.
    PwObjectTracker {
        objects: root.pipewireService && root.pipewireService.nodes && root.pipewireService.nodes.values ? root.pipewireService.nodes.values.filter((node) => {
            return node.audio !== null && !node.isStream;
        }) : []
    }

    function volumePercent() {
        return state.volumePercent();
    }

    function refresh() {
        // PipeWire state is signal-driven. Keep this method so the provider
        // has the same small interface as the former ScriptPoller owner.
    }

    function setVolume(value) {
        return state.setVolume(value);
    }

    function toggleMute() {
        return state.toggleMute();
    }

    function setMicMuted(value) {
        return state.setMicMuted(value);
    }
}
