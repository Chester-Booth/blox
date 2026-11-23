import QtQuick
import QtQuick.Layouts
import qs.shared

Rectangle {
    id: root

    property string label: ""
    property string detail: ""
    property real previewRadius: 1.25
    property real previewDensity: 1.0
    property real previewGap: 5
    property bool selected: false
    signal clicked()

    implicitHeight: 116
    radius: Theme.cardRadius
    color: selected ? Theme.withAlpha(Theme.accent, 0.14) : Theme.background
    border.color: activeFocus || selected ? Theme.accent : hover.hovered ? Theme.foreground : Theme.border
    border.width: activeFocus || selected ? 2 : 1
    activeFocusOnTab: true
    Keys.onReturnPressed: root.clicked()
    Keys.onSpacePressed: root.clicked()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(8)
        spacing: Theme.scaledSpacing(5)

        Text {
            Layout.fillWidth: true
            text: root.label
            color: Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 12
            font.bold: true
            elide: Text.ElideRight
        }

        SettingsShapePreview {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radiusScale: root.previewRadius
            densityScale: root.previewDensity
            windowGap: root.previewGap
        }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.clicked() }
}
