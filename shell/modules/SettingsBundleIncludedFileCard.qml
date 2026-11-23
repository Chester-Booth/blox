import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared as Shared

Rectangle {
    id: root
    required property var file
    required property var flowState
    property bool expanded: false

    implicitHeight: content.implicitHeight + Shared.Theme.scaledSpacing(14)
    radius: Shared.Theme.scaledRadius(7)
    color: Shared.Theme.background
    border.color: Shared.Theme.border

    ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Shared.Theme.scaledSpacing(7)
        spacing: Shared.Theme.scaledSpacing(6)

        RowLayout {
            Layout.fillWidth: true
            spacing: Shared.Theme.scaledSpacing(8)

            Shared.PhosphorIcon {
                Layout.preferredWidth: 15
                Layout.preferredHeight: 15
                iconName: "shield"
                iconColor: Shared.Theme.yellow
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: root.file.name
                    color: Shared.Theme.foreground
                    font.family: Shared.Theme.monoFontFamily
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideMiddle
                }
                Text {
                    Layout.fillWidth: true
                    text: root.file.reason
                    color: Shared.Theme.muted
                    font.family: Shared.Theme.bodyFontFamily
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
            }

            Shared.BloxCheckBox {
                text: "Approve"
                checked: root.flowState.approvedSensitiveFiles.indexOf(root.file.id) >= 0
                onToggled: value => root.flowState.approveSensitiveFile(root.file.id, value)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: previewText.implicitHeight + Shared.Theme.scaledSpacing(14)
                radius: Shared.Theme.scaledRadius(5)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border

                Text {
                    id: previewText
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(7)
                    text: root.file.viewMode === "expand" && !root.expanded
                        ? root.file.preview.split("\n").slice(0, 4).join("\n") + "\n…"
                        : root.file.preview
                    color: Shared.Theme.muted
                    font.family: Shared.Theme.monoFontFamily
                    font.pixelSize: 12
                    wrapMode: Text.WrapAnywhere
                }
            }

            Rectangle {
                id: expandButton
                objectName: "included-file-expand-" + root.file.id
                visible: root.file.viewMode !== "plain"
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                Layout.topMargin: -1
                z: 1
                radius: Shared.Theme.scaledRadius(5)
                color: expandHover.hovered ? Shared.Theme.surfaceAlt : Shared.Theme.surface
                border.color: activeFocus ? Shared.Theme.blue : expandHover.hovered ? Shared.Theme.withAlpha(Shared.Theme.foreground, 0.34) : Shared.Theme.border
                activeFocusOnTab: visible
                Keys.onReturnPressed: root.expanded = !root.expanded
                Keys.onSpacePressed: root.expanded = !root.expanded

                Row {
                    anchors.centerIn: parent
                    spacing: Shared.Theme.scaledSpacing(4)

                    Shared.PhosphorIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12
                        height: 12
                        iconName: root.expanded ? "caret-up" : "caret-down"
                        iconColor: Shared.Theme.foreground
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.expanded ? "Show less" : "Show more"
                        color: Shared.Theme.foreground
                        font.family: Shared.Theme.bodyFontFamily
                        font.pixelSize: 11
                    }
                }

                HoverHandler { id: expandHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.expanded = !root.expanded }
            }
        }
    }
}
