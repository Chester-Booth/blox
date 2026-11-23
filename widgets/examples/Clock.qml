import QtQuick
import Blox.Widgets 1.0

WidgetView {
    id: root
    readonly property var clock: context && context.data ? context.data.clock || null : null
    contentReady: !!snapshot && snapshot.state === "ready" && clock !== null
        && clock.state === "ready" && !!clock.value && typeof clock.value.epochMs === "number"
    Component.onCompleted: if (context && typeof context.requestData === "function") context.requestData("clock", {"style": "digital", "timezone": "local", "format": "24h", "showSeconds": false})
    Text {
        anchors.centerIn: parent
        text: root.contentReady ? Qt.formatTime(new Date(root.clock.value.epochMs), "HH:mm") : ""
        color: root.theme && root.theme.palette ? root.theme.palette.foreground : "#e8edf4"
        font.family: root.theme && root.theme.fontFamily ? root.theme.fontFamily : "Sans Serif"
        font.pixelSize: 48 * (root.theme && root.theme.densityScale !== undefined ? root.theme.densityScale : 1)
    }
}
