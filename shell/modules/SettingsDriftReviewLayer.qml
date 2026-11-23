import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.shared as Shared

Item {
    id: root
    required property var flowState
    property var settingsWindow: null
    property bool wasVisible: false
    anchors.fill: parent
    visible: flowState.driftReviewOpen
    z: 90
    onVisibleChanged: Qt.callLater(() => {
        if (visible) {
            wasVisible = true;
            closeButton.forceActiveFocus();
        } else if (wasVisible && settingsWindow) {
            settingsWindow.restoreFocusAfterDialog();
        }
    })

    Rectangle {
        anchors.fill: parent
        color: Shared.Theme.withAlpha("black", 0.72)
        TapHandler { onTapped: root.flowState.cancelDriftReview() }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - 56, 620)
        height: root.flowState.driftDetailsOpen ? 490 : 405
        radius: Shared.Theme.scaledRadius(10)
        color: Shared.Theme.background
        border.color: Shared.Theme.border

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Shared.Theme.scaledSpacing(19)
            spacing: Shared.Theme.scaledSpacing(11)

            RowLayout {
                Layout.fillWidth: true
                Shared.PhosphorIcon { Layout.preferredWidth: 23; Layout.preferredHeight: 23; iconName: "warning-circle"; iconColor: Shared.Theme.yellow }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: root.flowState.drift ? root.flowState.drift.target.toUpperCase() + " changed outside Blox" : ""; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 18; font.bold: true }
                    Text { text: "Apply paused before writing target files."; color: Shared.Theme.muted; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 11 }
                }
                Item { Layout.fillWidth: true }
                Shared.BloxButton {
                    id: closeButton
                    iconName: "x"
                    compact: true
                    Layout.alignment: Qt.AlignRight
                    onClicked: root.flowState.cancelDriftReview()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 90
                radius: Shared.Theme.scaledRadius(8)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(11)
                    spacing: Shared.Theme.scaledSpacing(6)
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: "Theme setting"; color: Shared.Theme.muted; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 10 }
                        Text { text: root.flowState.drift ? root.flowState.drift.observedAt : ""; color: Shared.Theme.muted; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 9 }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: root.flowState.drift ? root.flowState.drift.label : ""; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 12; font.bold: true }
                        Text { text: root.flowState.drift ? root.flowState.drift.expected + "  →  " + root.flowState.drift.current : ""; color: Shared.Theme.yellow; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 11; font.bold: true }
                    }
                    Text { text: "The current value differs from the one Blox last applied."; color: Shared.Theme.muted; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 10 }
                }
            }

            Rectangle {
                visible: root.flowState.driftDetailsOpen
                Layout.fillWidth: true
                Layout.preferredHeight: 110
                radius: Shared.Theme.scaledRadius(7)
                color: Shared.Theme.surface
                border.color: Shared.Theme.border
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Shared.Theme.scaledSpacing(10)
                    spacing: 4
                    Text { text: "Values and paths"; color: Shared.Theme.foreground; font.family: Shared.Theme.bodyFontFamily; font.pixelSize: 11; font.bold: true }
                    Text { text: root.flowState.drift ? "Blox wrote: " + root.flowState.drift.expected : ""; color: Shared.Theme.muted; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 9 }
                    Text { text: root.flowState.drift ? "Current: " + root.flowState.drift.current : ""; color: Shared.Theme.yellow; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 9 }
                    Text { text: root.flowState.drift ? root.flowState.drift.paths.join(" · ") : ""; color: Shared.Theme.muted; font.family: Shared.Theme.monoFontFamily; font.pixelSize: 9; elide: Text.ElideMiddle }
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.flowState.drift ? "Reapply writes only GTK from the active " + root.flowState.drift.managed + " generation. Keep external change disables GTK as a Blox target." : ""
                color: Shared.Theme.muted
                font.family: Shared.Theme.bodyFontFamily
                font.pixelSize: 10
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                Shared.BloxButton {
                    text: "View details"
                    compact: true
                    onClicked: root.flowState.driftDetailsOpen = !root.flowState.driftDetailsOpen
                }
                Item { Layout.fillWidth: true }
                Shared.BloxButton { text: "Cancel"; onClicked: root.flowState.cancelDriftReview() }
                Shared.BloxButton {
                    text: "Keep external change"
                    compact: true
                    onClicked: root.flowState.resolveExternalDrift()
                }
                Shared.BloxButton {
                    text: "Reapply Blox theme"
                    accent: Shared.Theme.blue
                    onClicked: root.flowState.reapplyDriftedTarget()
                }
            }
        }
    }
}
