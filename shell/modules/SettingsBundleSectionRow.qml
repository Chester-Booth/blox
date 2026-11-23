import QtQuick
import QtQuick.Layouts
import qs.shared as Shared

Rectangle {
    id: root

    property string label: ""
    property string detail: ""
    property string actionText: ""
    property string actionIcon: ""
    property bool checked: false
    property bool readOnly: false
    signal toggled(bool checked)
    signal actionClicked()

    implicitHeight: Math.max(38, detailText.implicitHeight + Shared.Theme.scaledSpacing(16))
    radius: Shared.Theme.scaledRadius(6)
    color: Shared.Theme.background
    border.color: Shared.Theme.border

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Shared.Theme.scaledSpacing(8)
        anchors.rightMargin: Shared.Theme.scaledSpacing(9)
        spacing: Shared.Theme.scaledSpacing(7)

        Shared.BloxCheckBox {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.label
            checked: root.checked
            enabled: root.enabled && !root.readOnly
            onToggled: value => root.toggled(value)
        }

        Text {
            id: detailText
            visible: root.actionText.length === 0
            Layout.fillWidth: true
            Layout.maximumWidth: 220
            text: root.detail
            color: Shared.Theme.muted
            font.family: Shared.Theme.bodyFontFamily
            font.pixelSize: 11
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
        }

        Shared.BloxButton {
            visible: root.actionText.length > 0
            text: root.actionText
            iconName: root.actionIcon
            compact: true
            Layout.preferredHeight: 26
            enabled: root.enabled && root.checked
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            onClicked: root.actionClicked()
        }
    }
}
