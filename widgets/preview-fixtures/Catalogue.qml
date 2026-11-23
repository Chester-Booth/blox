import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Blox.Widgets 1.0

Rectangle {
    id: root
    width: 1280
    height: 900
    color: previewConfig.canvas
    property int caseIndex: 0
    property bool nativeFullscreen: false
    property bool galleryMode: false
    property int workspaceIndex: 0
    property int scopeIndex: 0
    property real backgroundOpacity: 0.8
    property string presentation: "open"
    property real radiusScale: previewConfig.theme.radiusScale
    property real densityScale: previewConfig.theme.densityScale
    readonly property string phase: host.phase
    readonly property string viewError: host.error
    readonly property int generation: host.revealGeneration
    readonly property int fixtureSubscriptions: fixtures.subscriptions
    readonly property int fixtureActions: fixtures.actions
    readonly property bool galleryReady: {
        if (!galleryMode || galleryRepeater.count !== previewConfig.nativeCaseCount) return false;
        for (let i = 0; i < galleryRepeater.count; i++) {
            const item = galleryRepeater.itemAt(i);
            if (!item || item.hostPhase !== "visible") return false;
        }
        return true;
    }
    readonly property var currentCase: previewConfig.cases[caseIndex]
    readonly property var fakeWorkspace: previewConfig.workspaces[workspaceIndex]
    readonly property var registry: ({
        "example-clock": {source: Qt.resolvedUrl("../examples/Clock.qml"), layouts: ["native"], providers: ["clock"]},
        "example-music": {source: Qt.resolvedUrl("../examples/Music.qml"), layouts: ["native"], providers: ["music"]}
    })
    function profile(source, galleryWidth, galleryHeight) {
        const item = JSON.parse(JSON.stringify(source));
        item.placement.anchor = "centre";
        item.placement.x = 0; item.placement.y = 0;
        if (galleryWidth !== undefined) {
            item.placement.width = Math.floor(galleryWidth);
            item.placement.height = Math.floor(galleryHeight);
        }
        item.appearance.backgroundOpacity = backgroundOpacity;
        item.appearance.presentation = presentation;
        item.fullscreen.enabled = true;
        const scopes = [
            {mode: "all", ids: [], ranges: []},
            {mode: "include", ids: [1], ranges: []},
            {mode: "include", ids: [], ranges: [[3, 5]]},
            {mode: "include", ids: ["studio"], ranges: []},
            {mode: "include", ids: ["special:scratch"], ranges: []}
        ];
        item.workspaces = galleryWidth === undefined ? scopes[scopeIndex] : scopes[0];
        return item;
    }
    WidgetTheme {
        id: widgetTheme
        iconRoot: Qt.resolvedUrl("../../shell/assets/phosphor/")
        palette: previewConfig.theme.palette
        fontFamily: previewConfig.theme.fontFamily
        monospaceFamily: previewConfig.theme.monospaceFamily
        fontSize: previewConfig.theme.fontSize
        radiusScale: root.radiusScale
        densityScale: root.densityScale
    }
    Control {
        id: toolTheme
        visible: false
        palette.window: previewConfig.canvas
        palette.windowText: widgetTheme.palette.foreground
        palette.base: widgetTheme.palette.background
        palette.text: widgetTheme.palette.foreground
        palette.button: previewConfig.stage
        palette.buttonText: widgetTheme.palette.foreground
        palette.highlight: widgetTheme.palette.accent
        palette.highlightedText: widgetTheme.palette.background
        palette.mid: widgetTheme.palette.border
    }
    component Picker: ComboBox { palette: toolTheme.palette; font.family: widgetTheme.fontFamily; font.pixelSize: 13 }
    component ToolButton: Button { palette: toolTheme.palette; font.family: widgetTheme.fontFamily; font.pixelSize: 13 }
    component ToolCheck: CheckBox { palette: toolTheme.palette; font.family: widgetTheme.fontFamily; font.pixelSize: 13 }
    component ToolSlider: Slider { palette: toolTheme.palette }
    // This provider only returns checked-in fixtures. It imports no native adaptor.
    QtObject {
        id: fixtures
        property int subscriptions: 0
        property int actions: 0
        signal snapshotReady(string consumerId, var envelope)
        function subscribe(id, kind, options, generation) {
            subscriptions++;
            const value = previewConfig.values[kind];
            snapshotReady(id, {generation: generation, revision: 0, observedMonotonicMs: 1,
                state: value === undefined ? "unavailable" : "ready", value: value || {},
                error: value === undefined ? "No checked-in fixture" : ""});
        }
        function unsubscribe(id) {}
        function dispatchAction(id, action, payload) {
            actions++;
            console.log("Fixture action recorded, nothing executed:", action, JSON.stringify(payload));
        }
    }
    ColumnLayout {
        id: controls
        visible: !root.galleryMode
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 20
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            Text { text: "Fixture data"; color: widgetTheme.palette.foreground; font.family: widgetTheme.fontFamily; font.pixelSize: 16 }
            Picker { id: kindSelector; Layout.preferredWidth: 250; model: previewConfig.cases; textRole: "label"; currentIndex: root.caseIndex; onActivated: root.caseIndex = currentIndex }
            ToolCheck { text: "Fullscreen layout"; checked: root.nativeFullscreen; onToggled: root.nativeFullscreen = checked }
            Text { text: "Background"; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily }
            ToolSlider { Layout.preferredWidth: 130; from: 0; to: 1; value: root.backgroundOpacity; onMoved: root.backgroundOpacity = value }
            Item { Layout.fillWidth: true }
            ToolButton { text: "Catalogue grid"; onClicked: root.galleryMode = true }
        }
        RowLayout {
            Text { text: "Fake workspace"; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily }
            Picker { Layout.preferredWidth: 155; model: previewConfig.workspaces; textRole: "label"; currentIndex: root.workspaceIndex; onActivated: root.workspaceIndex = currentIndex }
            Picker { Layout.preferredWidth: 165; model: ["All workspaces", "ID 1", "Range 3 to 5", "Named studio", "Special scratch"]; currentIndex: root.scopeIndex; onActivated: root.scopeIndex = currentIndex }
            Text { text: "Roundness"; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily }
            ToolSlider { Layout.preferredWidth: 120; from: 0; to: 2; value: root.radiusScale; onMoved: root.radiusScale = value }
            Text { text: "Density"; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily }
            ToolSlider { Layout.preferredWidth: 120; from: 0.75; to: 1.5; value: root.densityScale; onMoved: root.densityScale = value }
            Picker { model: ["Open", "Compact"]; currentIndex: root.presentation === "compact" ? 1 : 0; onActivated: root.presentation = currentIndex === 1 ? "compact" : "open" }
            Text { text: root.phase; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily }
        }
    }
    Rectangle {
        id: stage
        visible: !root.galleryMode
        anchors.top: controls.bottom
        anchors.topMargin: 24
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 24
        color: previewConfig.stage
        WidgetHost {
            id: host
            visible: !root.galleryMode
            widget: root.profile(root.currentCase.widget)
            provider: fixtures
            theme: widgetTheme
            workspace: root.fakeWorkspace
            fullscreen: root.nativeFullscreen
            qmlRegistry: root.registry
        }
        Text { anchors.centerIn: parent; visible: host.phase !== "visible"; text: host.phase === "hidden" ? "Hidden on this fake workspace" : host.error || host.phase; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily }
    }
    Item {
        id: gallery
        anchors.fill: parent
        anchors.margins: 20
        visible: root.galleryMode
        Text { text: "Fixture data, native catalogue"; color: widgetTheme.palette.foreground; font.family: widgetTheme.fontFamily; font.pixelSize: 22 }
        ToolButton { anchors.right: parent.right; text: "Single widget"; onClicked: root.galleryMode = false }
        Item {
            anchors.fill: parent
            anchors.topMargin: 52
            Repeater {
                id: galleryRepeater
                model: root.galleryMode ? previewConfig.cases.slice(0, previewConfig.nativeCaseCount) : []
                Item {
                    required property int index
                    required property var modelData
                    readonly property string hostPhase: galleryHost.phase
                    x: index % 4 * (parent.width / 4)
                    y: Math.floor(index / 4) * (parent.height / 4)
                    width: parent.width / 4 - 14
                    height: parent.height / 4 - 14
                    Text { text: modelData.label; color: widgetTheme.palette.muted; font.family: widgetTheme.fontFamily; font.pixelSize: 13 }
                    WidgetHost {
                        id: galleryHost
                        visible: root.galleryMode
                        placementBounds: Qt.rect(0, 25, parent.width, parent.height - 25)
                        widget: root.profile(modelData.widget, parent.width, parent.height - 25)
                        provider: fixtures
                        theme: widgetTheme
                    }
                }
            }
        }
    }
}
