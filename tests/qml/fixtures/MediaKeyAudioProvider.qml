import QtQuick
import "../../../shell/services" as Services

// Production PipeWire state/actions, with only its service and nodes replaced.
Services.PipewireAudioProvider {
    id: root
    property alias volume: sinkAudio.volume
    property alias muted: sinkAudio.muted
    property alias micMuted: sourceAudio.muted
    property alias ready: service.ready
    property alias output: service.defaultAudioSink
    property alias input: service.defaultAudioSource

    QtObject { id: sinkAudio; property real volume: 0.5; property bool muted: false }
    QtObject { id: sourceAudio; property real volume: 0.5; property bool muted: false }
    QtObject { id: sinkNode; property var audio: sinkAudio; property bool ready: true; property string name: "fake-sink" }
    QtObject { id: sourceNode; property var audio: sourceAudio; property bool ready: true; property string name: "fake-source" }
    QtObject { id: nodes; property var values: [] }
    QtObject {
        id: service
        property bool ready: true
        property var nodes: nodes
        property var defaultAudioSink: sinkNode
        property var defaultAudioSource: sourceNode
    }
    pipewireService: service
}
