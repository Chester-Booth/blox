import QtQuick
import QtQuick.Window
import QtQuick.Effects
import QtQuick.Layouts

NativeView {
    id: root
    readonly property string style: settings.style || "card"
    readonly property bool radial: style === "radial"
    readonly property bool compact: !radial && (style === "compact" || compactPresentation)
    readonly property bool playing: observation.playbackState === "Playing"
    readonly property real progress: numeric(observation.positionSeconds) && numeric(observation.lengthSeconds) && observation.lengthSeconds > 0 ? Math.max(0, Math.min(1, observation.positionSeconds / observation.lengthSeconds)) : -1
    readonly property bool artworkWanted: settings.showArtwork !== false && !!observation.artUrl
        && (radial || compact || fullscreen)
    readonly property bool artworkHasArea: artwork.width > 0 && artwork.height > 0
    readonly property bool softwareArtwork: GraphicsInfo.api === GraphicsInfo.Software && (rounding > 0 || radial)
    readonly property bool artworkReady: softwareArtwork ? !!softwareArt.item && softwareArt.item.ready : art.currentArtworkReady
    readonly property bool artworkFailed: softwareArtwork ? !!softwareArt.item && softwareArt.item.failed : art.status === Image.Error
    contentReady: dataReady && width > 0 && height > 0 && (!artworkWanted || !artworkHasArea || artworkReady || artworkFailed)
    implicitWidth: 380
    implicitHeight: radial ? 360 : compact ? 150 : 280
    function duration(seconds) { return numeric(seconds) ? Math.floor(seconds / 60) + ":" + String(Math.floor(seconds % 60)).padStart(2, "0") : "Unavailable"; }
    Item {
        id: content
        anchors.centerIn: parent
        width: Math.max(0, Math.min(parent.width - root.padding * 2, root.fullscreen ? 1100 : parent.width))
        height: Math.max(0, parent.height - root.padding * 2)
        Item {
            id: artwork
            objectName: "musicArtwork"
            width: root.radial ? Math.max(0, Math.min(content.width * 0.78, content.height * 0.64,
                    content.height - controls.height - metadata.implicitHeight - 24 * root.density))
                : Math.max(0, Math.min(content.height * (root.compact ? 0.5 : 0.42), 100 * root.displayScale,
                    progressColumn.y - root.gap))
            height: width
            x: root.radial ? (content.width - width) / 2 : 0
            y: root.radial ? 0 : 0
            visible: root.radial || root.artworkWanted
            Rectangle { anchors.fill: parent; anchors.margins: root.radial ? parent.width * 0.08 : 0; radius: root.radial ? width / 2 : 8 * root.rounding; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08) }
            Image {
                id: art
                objectName: "musicArtworkImage"
                property url readySource: ""
                readonly property bool currentArtworkReady: String(readySource) !== ""
                    && String(readySource) === String(source) && status !== Image.Error
                function rememberReadySource() {
                    if (status === Image.Ready) readySource = source;
                }
                anchors.fill: parent
                anchors.margins: root.radial ? parent.width * 0.15 : 0
                source: root.artworkWanted && root.artworkHasArea && !root.softwareArtwork ? root.observation.artUrl : ""
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(Math.max(1, Math.ceil(width * Screen.devicePixelRatio)),
                    Math.max(1, Math.ceil(height * Screen.devicePixelRatio)))
                layer.enabled: GraphicsInfo.api !== GraphicsInfo.Software && (root.rounding > 0 || root.radial)
                layer.effect: MultiEffect { maskEnabled: true; maskSource: artMask }
                asynchronous: true
                retainWhileLoading: true
                visible: currentArtworkReady
                onStatusChanged: rememberReadySource()
                onSourceChanged: {
                    readySource = "";
                    // Cached synchronous loads can remain Ready without another status change.
                    Qt.callLater(rememberReadySource);
                }
            }
            Loader {
                id: softwareArt
                anchors.fill: art
                active: root.softwareArtwork && root.artworkWanted && root.artworkHasArea
                sourceComponent: SoftwareArtwork {
                    objectName: "softwareArtwork"
                    source: root.observation.artUrl || ""
                    sourceSize: art.sourceSize
                    cornerRadius: artMask.radius
                }
            }
            Rectangle {
                id: artMask
                anchors.fill: art
                radius: root.radial ? width / 2 : Math.min(width / 2, height / 2, 8 * root.rounding)
                color: "white"
                visible: false
                layer.enabled: GraphicsInfo.api !== GraphicsInfo.Software
            }
            Text { anchors.centerIn: parent; visible: !root.artworkReady; text: "Music"; color: root.muted; font.family: root.bodyFont; font.pixelSize: Math.max(1, Math.min(root.baseSize, parent.width / 5)) }
            MetricRing { anchors.fill: parent; visible: root.radial; value: root.progress; stroke: root.positive }
        }
        Column {
            id: metadata
            objectName: "musicMetadata"
            x: root.radial ? 0 : artwork.visible ? artwork.width + 18 * root.density : 0
            y: root.radial ? artwork.height + 8 * root.density : Math.max(0, (artwork.height - height) / 2)
            width: root.radial ? content.width : Math.max(0, content.width - x)
            spacing: (root.compact ? 4 : 6) * root.density
            Text { width: parent.width; text: root.observation.title || "No track"; color: root.foreground; font.family: root.bodyFont; font.pixelSize: Math.min((root.compact ? 21 : 25) * root.displayScale, content.height / 4); horizontalAlignment: root.radial ? Text.AlignHCenter : Text.AlignLeft; elide: Text.ElideRight }
            Text { width: parent.width; text: [root.observation.artist, root.observation.album].filter(Boolean).join(" · "); color: root.muted; font.family: root.bodyFont; font.pixelSize: root.baseSize * root.displayScale; horizontalAlignment: root.radial ? Text.AlignHCenter : Text.AlignLeft; elide: Text.ElideRight }
        }
        Column {
            id: progressColumn
            objectName: "musicProgress"
            anchors.bottom: controls.top
            anchors.bottomMargin: root.gap
            width: parent.width
            spacing: 4 * root.density
            visible: !root.radial
            Rectangle { width: parent.width; height: 3 * root.displayScale; radius: Math.min(height / 2, 2 * root.rounding); color: root.borderColour; Rectangle { width: parent.width * Math.max(0, root.progress); height: parent.height; radius: parent.radius; color: root.accent } }
            RowLayout { visible: !root.compact; width: parent.width
                Text { text: root.duration(root.observation.positionSeconds); color: root.muted; font.family: root.monoFont; font.pixelSize: 12 * root.displayScale }
                Item { Layout.fillWidth: true }
                Text { text: root.duration(root.observation.lengthSeconds); color: root.muted; font.family: root.monoFont; font.pixelSize: 12 * root.displayScale }
            }
        }
        Text {
            visible: root.compact
            anchors.left: parent.left
            y: controls.y + (controls.height - height) / 2
            text: root.duration(root.observation.positionSeconds)
            color: root.muted
            font.family: root.monoFont
            font.pixelSize: 11 * root.displayScale
        }
        Text {
            visible: root.compact
            anchors.right: parent.right
            y: controls.y + (controls.height - height) / 2
            text: root.duration(root.observation.lengthSeconds)
            color: root.muted
            font.family: root.monoFont
            font.pixelSize: 11 * root.displayScale
        }
        Row {
            id: controls
            objectName: "musicControls"
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: (root.compact ? 8 : 22) * root.density
            NativeAction { text: "Back"; Accessible.name: "Previous track"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; pixelSize: 14 * root.displayScale; fontFamily: root.bodyFont; density: root.density; enabled: !!root.observation.canGoPrevious; onClicked: root.actionRequested("previous", {}) }
            NativeAction { text: root.playing ? "Pause" : "Play"; Accessible.name: root.playing ? "Pause" : "Play"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; pixelSize: 14 * root.displayScale; fontFamily: root.bodyFont; density: root.density; enabled: root.playing ? !!root.observation.canPause : !!root.observation.canPlay; onClicked: root.actionRequested("playPause", {}) }
            NativeAction { text: "Next"; Accessible.name: "Next track"; foreground: root.foreground; accent: root.accent; rounding: root.rounding; pixelSize: 14 * root.displayScale; fontFamily: root.bodyFont; density: root.density; enabled: !!root.observation.canGoNext; onClicked: root.actionRequested("next", {}) }
        }
    }
}
