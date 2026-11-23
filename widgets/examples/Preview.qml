import QtQuick
import QtQuick.Window
import Blox.Widgets 1.0

Window {
    id: window
    width: 720
    height: 420
    visible: true
    title: "Widget SDK preview, simulated data"
    color: "#101318"
    WidgetTheme { id: previewTheme }
    // This fixture emits labelled simulated observations. It never contacts a live service.
    QtObject {
        id: simulatedProvider
        signal snapshotReady(string consumerId, var envelope)
        function subscribe(id, kind, options, generation) {
            var value = kind === "clock" ? {epochMs: new Date(2026, 9, 18, 14, 35).getTime()} : {title: "Example track"};
            snapshotReady(id, {generation: generation, revision: 0, observedMonotonicMs: 0,
                state: "ready", value: value, error: ""});
        }
        function unsubscribe(id) {}
        function dispatchAction(id, action, payload) { console.log("Preview action", action); }
    }
    function profile(id, manifest, provider, x) {
        return {id: id, kind: "qml", name: manifest, enabled: true,
            placement: {anchor: "top-left", x: x, y: 64, width: 300, height: 240},
            workspaces: {mode: "all", ids: [], ranges: []}, visibility: "always",
            appearance: {backgroundOpacity: 1, scrollbars: "auto"}, fullscreen: {enabled: true, mode: "native"},
            settings: {manifest: manifest, layouts: ["native"], providers: [provider], settings: {}}};
    }
    readonly property var manifests: ({
        "example-clock": {source: Qt.resolvedUrl("Clock.qml"), layouts: ["native"], providers: ["clock"]},
        "example-music": {source: Qt.resolvedUrl("Music.qml"), layouts: ["native"], providers: ["music"]}
    })
    Text {
        x: 24; y: 20
        text: "Simulated data"
        color: previewTheme.palette.muted
        font.family: previewTheme.fontFamily
    }
    WidgetHost {
        widget: window.profile("clock-preview", "example-clock", "clock", 24)
        qmlRegistry: window.manifests
        theme: previewTheme
        provider: simulatedProvider
    }
    WidgetHost {
        widget: window.profile("music-preview", "example-music", "music", 360)
        qmlRegistry: window.manifests
        theme: previewTheme
        provider: simulatedProvider
    }
}
