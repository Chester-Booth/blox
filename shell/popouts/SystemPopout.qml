import qs.shared
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property alias mode: controller.mode
    property alias title: controller.title
    property alias body: controller.body
    property alias statusError: controller.statusError
    property alias actionError: controller.actionError
    property alias actions: controller.actions
    property alias scriptRoot: controller.scriptRoot
    property alias audioVolume: controller.audioVolume
    property alias audioIcon: controller.audioIcon
    property alias audioMuted: controller.audioMuted
    property alias micMuted: controller.micMuted
    property alias micCanChange: controller.micCanChange
    property alias audioProvider: controller.audioProvider
    property alias networkEnabled: controller.networkEnabled
    property alias bluetoothEnabled: controller.bluetoothEnabled
    property alias audioCanChange: controller.audioCanChange
    property alias networkCanChange: controller.networkCanChange
    property alias bluetoothCanChange: controller.bluetoothCanChange
    property alias networkProvider: controller.networkProvider
    property alias bluetoothProvider: controller.bluetoothProvider
    property alias brightnessProvider: controller.brightnessProvider
    property alias brightnessCanChange: controller.brightnessCanChange
    property alias wifiIcon: controller.wifiIcon
    property alias wifiText: controller.wifiText
    property alias bluetoothIcon: controller.bluetoothIcon
    property alias brightnessIcon: controller.brightnessIcon
    property alias brightnessPercent: controller.brightnessPercent
    property alias blueLightMode: controller.blueLightMode
    property alias blueLightActive: controller.blueLightActive
    property var keyboardFocusWindow: null

    signal action(string command, bool keepOpen)
    signal sectionSelected(string panel)
    signal levelPreview(string kind, int value, bool muted)

    function requestKeyboardFocus(item) {
        if (keyboardFocusWindow && keyboardFocusWindow.requestKeyboardFocus)
            keyboardFocusWindow.requestKeyboardFocus();
        if (item && item.forceActiveFocus)
            item.forceActiveFocus();
    }

    width: 330
    height: Math.min(520, Math.max(178, content.implicitHeight + 24))
    radius: Theme.scaledRadius(8)
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
        anchors.margins: Theme.scaledSpacing(12)
        spacing: Theme.scaledSpacing(12)

        Column {
            Layout.preferredWidth: 38
            spacing: Theme.scaledSpacing(8)

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
                    id: sectionButton
                    required property var modelData

                    icon: modelData.icon
                    label: modelData.panel.charAt(0).toUpperCase() + modelData.panel.slice(1)
                    active: controller.currentMode() === modelData.panel
                    onClicked: {
                        root.requestKeyboardFocus(sectionButton);
                        root.sectionSelected(modelData.panel);
                    }
                }

            }

        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.scaledSpacing(10)

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.scaledSpacing(10)

                Rectangle {
                    width: 30
                    height: 30
                    radius: Theme.scaledRadius(7)
                    color: controller.currentMode() === "audio" && headerIconMouse.containsMouse ? Theme.surfaceAlt : "transparent"
                    activeFocusOnTab: controller.currentMode() === "audio" && controller.audioCanChange
                    Accessible.role: Accessible.Button
                    Accessible.name: controller.audioMuted ? "Unmute audio" : "Mute audio"
                    Keys.onReturnPressed: toggleAudio()
                    Keys.onEnterPressed: toggleAudio()
                    Keys.onSpacePressed: toggleAudio()

                    function toggleAudio() {
                        root.requestKeyboardFocus(this);
                        controller.toggleAudio();
                    }

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
                        onClicked: parent.toggleAudio()
                    }

                    BloxToolTip {
                        shown: headerIconMouse.containsMouse
                        text: controller.audioMuted ? "Unmute audio" : "Mute audio"
                    }

                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.scaledSpacing(2)

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

                BloxButton {
                    id: appSettingsButton
                    width: 30
                    height: 30
                    compact: true
                    text: ""
                    iconName: "gear-six"
                    iconSize: 15
                    radius: Theme.scaledRadius(7)
                visible: controller.actionByLabel("open app") !== null
                Accessible.name: "Open app settings"
                    onClicked: {
                        root.requestKeyboardFocus(appSettingsButton);
                        controller.runLabel("open app", false);
                    }
                    BloxToolTip { shown: appSettingsButton.hovered; text: "Open app settings" }
                }

            }

            SystemAudioSection {
                controller: controller
                onKeyboardFocusRequested: item => root.requestKeyboardFocus(item)
            }

            SystemConnectivitySection {
                controller: controller
            }

            SystemDisplaySection {
                controller: controller
                onKeyboardFocusRequested: item => root.requestKeyboardFocus(item)
            }

            Text {
                id: feedbackMessage

                Layout.fillWidth: true
                objectName: "systemFeedbackMessage"
                visible: controller.feedbackText.length > 0
                text: controller.feedbackText
                color: controller.feedbackIsError ? Theme.red : Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 12
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
            }

        }

    }

}
