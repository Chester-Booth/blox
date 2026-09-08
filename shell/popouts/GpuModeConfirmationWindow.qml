import qs.shared
import QtQuick
import QtQuick.Layouts
import Quickshell

FloatingWindow {
    id: root

    property var provider: null
    property var targetScreen: null
    readonly property bool confirmationOpen: root.provider && root.provider.confirmationRequired === true
    readonly property string requestedMode: root.provider ? String(root.provider.requestedMode || "") : ""
    readonly property string requestedModeLabel: root.requestedMode.length > 0 ? root.requestedMode.charAt(0).toUpperCase() + root.requestedMode.slice(1) : "GPU mode"
    readonly property var activeClients: root.provider && Array.isArray(root.provider.activeClients) ? root.provider.activeClients : []
    readonly property bool switchingToIntegrated: root.requestedMode === "integrated"

    title: "Blox GPU mode confirmation"
    implicitWidth: 320
    implicitHeight: root.activeClients.length > 0 ? 250 : 190
    minimumSize: Qt.size(320, implicitHeight)
    maximumSize: Qt.size(320, implicitHeight)
    screen: root.targetScreen
    visible: root.confirmationOpen
    color: "transparent"
    onClosed: {
        if (root.confirmationOpen)
            root.provider.cancelModeRequest();
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(1)
        radius: Theme.scaledRadius(10)
        color: Theme.surface
        border.color: Theme.border
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(14)
            spacing: Theme.scaledSpacing(9)

            Text {
                Layout.fillWidth: true
                text: "Switch to " + root.requestedModeLabel + "?"
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 14
                font.bold: true
            }

            Text {
                Layout.fillWidth: true
                text: root.switchingToIntegrated ? "HDMI will turn off. Changing GPU mode will log you out. Open apps will close." : "Changing GPU mode will log you out. Open apps will close."
                color: Theme.muted
                font.family: Theme.bodyFontFamily
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

            Rectangle {
                visible: root.activeClients.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 54 : 0
                radius: Theme.scaledRadius(6)
                color: Theme.withAlpha(Theme.yellow, 0.08)
                border.color: Theme.withAlpha(Theme.yellow, 0.35)

                Text {
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(8)
                    text: root.activeClients.slice(0, 4).map(client => client.name).join("\n") + (root.activeClients.length > 4 ? "\n+ " + (root.activeClients.length - 4) + " more" : "")
                    color: Theme.yellow
                    font.family: Theme.monoFontFamily
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true

                Item { Layout.fillWidth: true }

                BloxButton {
                    text: "Cancel"
                    onClicked: root.provider.cancelModeRequest()
                }

                BloxButton {
                    text: "Switch and log out"
                    accent: Theme.yellow
                    checked: true
                    onClicked: root.provider.confirmModeRequest()
                }
            }
        }
    }
}
