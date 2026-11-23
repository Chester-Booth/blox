import QtQuick
import Blox.Widgets 1.0

WidgetView {
    id: root
    readonly property var music: context.data ? context.data.music : null
    contentReady: snapshot !== null && snapshot.state === "ready" && music !== null && music.state === "ready"
    Component.onCompleted: context.requestData("music", {"style": "card", "player": "", "showArtwork": true})
    Column {
        anchors.centerIn: parent
        spacing: 12 * root.theme.densityScale
        Text {
            text: root.contentReady ? root.music.value.title : ""
            color: root.theme.palette.foreground
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
        }
        Text {
            text: "Play / pause"
            color: root.theme.palette.accent
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.fontSize
            MouseArea {
                anchors.fill: parent
                onClicked: root.context.requestAction("playPause", {}, "music")
            }
        }
    }
}
