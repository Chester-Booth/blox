import "../shared"
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property alias mode: controller.mode
    property alias title: controller.title
    property alias body: controller.body
    property alias statusError: controller.statusError
    property alias actions: controller.actions
    property alias scriptRoot: controller.scriptRoot
    property alias audioVolume: controller.audioVolume
    property alias audioIcon: controller.audioIcon
    property alias audioMuted: controller.audioMuted
    property alias micMuted: controller.micMuted
    property alias networkEnabled: controller.networkEnabled
    property alias bluetoothEnabled: controller.bluetoothEnabled
    property alias audioCanChange: controller.audioCanChange
    property alias networkCanChange: controller.networkCanChange
    property alias bluetoothCanChange: controller.bluetoothCanChange
    property alias brightnessCanChange: controller.brightnessCanChange
    property alias wifiIcon: controller.wifiIcon
    property alias wifiText: controller.wifiText
    property alias bluetoothIcon: controller.bluetoothIcon
    property alias brightnessIcon: controller.brightnessIcon
    property alias brightnessPercent: controller.brightnessPercent
    property alias blueLightMode: controller.blueLightMode
    property alias blueLightActive: controller.blueLightActive

    signal action(string command, bool keepOpen)
    signal sectionSelected(string panel)
    signal levelPreview(string kind, int value, bool muted)

    width: 330
    height: Math.min(520, Math.max(178, content.implicitHeight + 24))
    radius: 8
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1

    SystemPopoutController {
        id: controller

        onActionRequested: (command, keepOpen) => {
            root.action(command, keepOpen);
        }
        onLevelPreviewRequested: (kind, value, muted) => {
            root.levelPreview(kind, value, muted);
        }
    }

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.margins: 12
        spacing: 12

        Column {
            Layout.preferredWidth: 38
            spacing: 8

            Repeater {
                model: [{
                    "panel": "network",
                    "icon": controller.wifiIcon
                }, {
                    "panel": "bluetooth",
                    "icon": controller.bluetoothIcon
                }, {
                    "panel": "audio",
                    "icon": controller.audioIcon
                }, {
                    "panel": "brightness",
                    "icon": controller.brightnessIcon
                }]

                SystemSectionButton {
                    required property var modelData

                    icon: modelData.icon
                    active: controller.currentMode() === modelData.panel
                    onClicked: root.sectionSelected(modelData.panel)
                }

            }

        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    width: 30
                    height: 30
                    radius: 7
                    color: controller.currentMode() === "audio" && headerIconMouse.containsMouse ? Theme.surfaceAlt : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: controller.heroIcon()
                        color: controller.audioOverdriven ? Theme.red : controller.currentMode() === "brightness" ? Theme.yellow : Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: 24
                    }

                    MouseArea {
                        id: headerIconMouse

                        anchors.fill: parent
                        enabled: controller.currentMode() === "audio" && controller.audioCanChange
                        hoverEnabled: true
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: controller.runCommand(controller.scriptRoot + "/control.sh audio-toggle", true)
                    }

                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        Layout.fillWidth: true
                        text: controller.title
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 15
                        font.bold: true
                    }

                    Text {
                        Layout.fillWidth: true
                        text: controller.subtitle()
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }

                }

                Rectangle {
                    width: 30
                    height: 30
                    radius: 7
                    color: cogMouse.containsMouse ? Theme.surfaceAlt : Theme.surface
                    border.color: Theme.surfaceAlt
                    border.width: 1
                    visible: controller.actionByLabel("open app") !== null

                    Text {
                        anchors.centerIn: parent
                        text: "󰒓"
                        color: Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: 14
                    }

                    MouseArea {
                        id: cogMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: controller.runLabel("open app", false)
                    }

                }

            }

            SystemAudioSection {
                controller: controller
            }

            SystemConnectivitySection {
                controller: controller
            }

            SystemDisplaySection {
                controller: controller
            }

            Text {
                Layout.fillWidth: true
                visible: controller.statusError.length > 0 || (controller.body.length > 0 && controller.currentMode() !== "network" && controller.currentMode() !== "bluetooth" && controller.currentMode() !== "brightness")
                text: controller.statusError.length > 0 ? "Status error: " + controller.statusError + (controller.body.length > 0 ? "\n" + controller.body : "") : controller.body
                color: controller.statusError.length > 0 ? Theme.red : Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
            }

        }

    }

}
