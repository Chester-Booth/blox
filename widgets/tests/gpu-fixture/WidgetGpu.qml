import QtQuick
import Blox.Widgets 1.0
import "../fixtures" as Fixture

Item {
    id: root
    width: 640; height: 360
    property var caseData: null
    property var observation: ({})
    property var themeData: ({})
    property int revision: 0
    readonly property string phase: host.phase
    readonly property string error: host.error
    readonly property int generation: host.revealGeneration
    readonly property real contentInset: host.view && host.view.padding !== undefined ? host.view.padding : 0
    readonly property real cellHeight: host.view && host.view.cellHeight !== undefined ? host.view.cellHeight : 0
    function publish() { revision++; fixtures.deliver(host.consumerId, host.revealGeneration); }
    function hideHost() { host.visible = false; }
    function revealHost() { host.visible = true; }
    Fixture.TerminalFixtureDecoder { id: decoder }
    WidgetTheme {
        id: fixtureTheme
        iconRoot: "file:///shell/assets/phosphor/"
        palette: root.themeData.palette || ({})
        fontFamily: root.themeData.fontFamily || "Sans Serif"
        monospaceFamily: root.themeData.monospaceFamily || "monospace"
        fontSize: root.themeData.fontSize || 14
        radiusScale: root.caseData ? root.caseData.radiusScale : 0
        densityScale: root.themeData.densityScale || 1
    }
    QtObject {
        id: fixtures
        signal snapshotReady(string consumerId, var envelope)
        function deliver(id, generation) {
            const terminal = root.caseData.widget.kind === "terminal";
            const envelope = {generation: generation, revision: root.revision,
                observedMonotonicMs: 1, state: "ready", value: terminal ? Object.assign({},root.observation,{generation:generation}) : root.observation, error: ""};
            snapshotReady(id, terminal ? decoder.adapt(id, envelope) : envelope);
        }
        function subscribe(id, kind, options, generation) { deliver(id, generation); }
        function unsubscribe(id) { decoder.release(id); }
        function dispatchAction(id, action, payload) {}
    }
    WidgetHost {
        id: host
        objectName: "fixtureHost"
        widget: root.caseData ? root.caseData.widget : null
        fullscreen: root.caseData ? root.caseData.fullscreen : false
        provider: fixtures
        theme: fixtureTheme
    }
}
