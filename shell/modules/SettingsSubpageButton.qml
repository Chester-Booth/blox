import QtQuick
import QtQuick.Layouts
import qs.shared

Rectangle {
    id: root

    property string text: ""
    property string detail: ""
    property string iconName: "arrow-right"
    signal clicked()

    implicitHeight: detail.length > 0 ? 54 : 42
    radius: Theme.scaledRadius(9)
    color: hover.hovered ? Theme.withAlpha(Theme.surfaceAlt, 0.68) : Theme.surface
    border.color: activeFocus || hover.hovered ? Theme.blue : Theme.border
    border.width: activeFocus ? 2 : 1
    activeFocusOnTab: true
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()

    RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(10)
        spacing: Theme.scaledSpacing(9)
        PhosphorIcon {
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18
            iconName: root.iconName
            iconColor: Theme.blue
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: root.text
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: root.detail.length > 0
                text: root.detail
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }
        Text { text: "›"; color: Theme.muted; font.pixelSize: 19 }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.clicked() }
}
