import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    // Calendar surfaces share this layout so failure states keep the chosen mock structure.
    property var notice: null
    property color tone: notice && notice.severity === "warning" ? Theme.yellow : Theme.red
    property string actionText: ""
    property bool actionEnabled: true

    signal actionTriggered()

    implicitHeight: content.implicitHeight + 20
    radius: Theme.scaledRadius(8)
    color: Theme.withAlpha(tone, 0.12)
    border.color: tone

    RowLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Theme.scaledSpacing(10)
        spacing: Theme.scaledSpacing(9)

        Rectangle {
            Layout.preferredWidth: 7
            Layout.preferredHeight: 7
            radius: Theme.scaledRadius(4)
            color: root.tone
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(2)

            Text {
                Layout.fillWidth: true
                text: root.notice ? (root.notice.heading || root.notice.message || "") : ""
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 11
                font.bold: true
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.notice ? (root.notice.detail || "") : ""
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }

        }

        BloxButton {
            visible: root.actionText.length > 0
            compact: true
            text: root.actionText
            enabled: root.actionEnabled
            onClicked: root.actionTriggered()
        }

    }

}
