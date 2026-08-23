import "."
import "../shared"
import QtQuick
import QtQuick.Layouts

FocusScope {
    id: colourFocusScope

    required property ThemePickerController controller

    function focusEditor() {
        colourHexField.focusEditor(true);
    }

    anchors.fill: parent
    visible: controller.colourPickerOpen
    focus: visible
    z: 60

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha("#000000", 0.68)
    }

    MouseArea {
        id: colourInputBlocker

        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        preventStealing: true
    }

    Rectangle {
        anchors.centerIn: parent
        width: 620
        height: 500
        radius: Theme.scaledRadius(14)
        color: Theme.surface
        border.color: Theme.border
        border.width: 1

        MouseArea {
            id: colourCardInputBlocker

            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            preventStealing: true
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(20)
            spacing: Theme.scaledSpacing(14)

            RowLayout {
                Layout.fillWidth: true

                ColumnLayout {
                    spacing: Theme.scaledSpacing(2)

                    Text {
                        text: "Choose " + controller.colourPickerKey.replace(/_/g, " ")
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 20
                        font.bold: true
                    }

                    Text {
                        text: controller.colourPickerTarget ? "Override for " + controller.colourPickerTarget : "Semantic theme colour"
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                    }

                }

                Item {
                    Layout.fillWidth: true
                }

                BloxButton {
                    id: colourDoneButton

                    text: "Done"
                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    onClicked: controller.dismissColourPicker()
                }

            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.scaledSpacing(16)

                ColumnLayout {
                    Layout.preferredWidth: 344
                    Layout.minimumWidth: 300
                    Layout.fillHeight: true
                    spacing: Theme.scaledSpacing(10)

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 230
                        radius: Theme.scaledRadius(9)
                        color: controller.hsvHex(controller.colourHue, 1, 1)
                        clip: true

                        Rectangle {
                            anchors.fill: parent

                            gradient: Gradient {
                                orientation: Gradient.Horizontal

                                GradientStop {
                                    position: 0
                                    color: "#ffffff"
                                }

                                GradientStop {
                                    position: 1
                                    color: "#00ffffff"
                                }

                            }

                        }

                        Rectangle {
                            anchors.fill: parent

                            gradient: Gradient {
                                orientation: Gradient.Vertical

                                GradientStop {
                                    position: 0
                                    color: "#00000000"
                                }

                                GradientStop {
                                    position: 1
                                    color: "#000000"
                                }

                            }

                        }

                        Rectangle {
                            x: controller.colourSaturation * parent.width - width / 2
                            y: (1 - controller.colourValue) * parent.height - height / 2
                            width: 14
                            height: 14
                            radius: Theme.scaledRadius(7)
                            color: "transparent"
                            border.color: Theme.foreground
                            border.width: 2
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (mouse) => {
                                controller.colourSaturation = Math.max(0, Math.min(1, mouse.x / width));
                                controller.colourValue = Math.max(0, Math.min(1, 1 - mouse.y / height));
                                controller.updatePickerColour();
                            }
                            onPositionChanged: (mouse) => {
                                if (pressed) {
                                    controller.colourSaturation = Math.max(0, Math.min(1, mouse.x / width));
                                    controller.colourValue = Math.max(0, Math.min(1, 1 - mouse.y / height));
                                    controller.updatePickerColour();
                                }
                            }
                        }

                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 22
                        Layout.minimumHeight: 22
                        Layout.maximumHeight: 22
                        radius: Theme.scaledRadius(7)

                        Rectangle {
                            x: controller.colourHue * parent.width - width / 2
                            y: -3
                            width: 6
                            height: parent.height + 6
                            radius: Theme.scaledRadius(3)
                            color: Theme.foreground
                            border.color: Theme.background
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (mouse) => {
                                controller.colourHue = Math.max(0, Math.min(1, mouse.x / width));
                                controller.updatePickerColour();
                            }
                            onPositionChanged: (mouse) => {
                                if (pressed) {
                                    controller.colourHue = Math.max(0, Math.min(1, mouse.x / width));
                                    controller.updatePickerColour();
                                }
                            }
                        }

                        gradient: Gradient {
                            orientation: Gradient.Horizontal

                            GradientStop {
                                position: 0
                                color: "#ff0000"
                            }

                            GradientStop {
                                position: 0.1667
                                color: "#ffff00"
                            }

                            GradientStop {
                                position: 0.3333
                                color: "#00ff00"
                            }

                            GradientStop {
                                position: 0.5
                                color: "#00ffff"
                            }

                            GradientStop {
                                position: 0.6667
                                color: "#0000ff"
                            }

                            GradientStop {
                                position: 0.8333
                                color: "#ff00ff"
                            }

                            GradientStop {
                                position: 1
                                color: "#ff0000"
                            }

                        }

                    }

                }

                ColumnLayout {
                    Layout.preferredWidth: 220
                    Layout.fillHeight: true
                    spacing: Theme.scaledSpacing(10)

                    Rectangle {
                        Layout.fillWidth: true
                        height: 74
                        radius: Theme.scaledRadius(10)
                        color: controller.colourHex
                        border.color: Theme.border

                        Text {
                            anchors.centerIn: parent
                            text: controller.colourHex
                            color: controller.swatchText(parent.color)
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                        }

                    }

                    Text {
                        text: "Theme colours"
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.scaledSpacing(6)

                        Repeater {
                            model: controller.semanticKeys

                            Rectangle {
                                required property string modelData

                                width: 34
                                height: 34
                                radius: Theme.scaledRadius(8)
                                color: controller.candidate ? controller.validColour(controller.candidate.colours[modelData], "transparent") : "transparent"
                                border.color: presetHover.hovered ? Theme.foreground : Theme.border

                                HoverHandler {
                                    id: presetHover

                                    cursorShape: Qt.PointingHandCursor
                                }

                                TapHandler {
                                    onTapped: {
                                        controller.loadPickerColour(parent.color);
                                        controller.applyPickerColour(controller.colourHex);
                                    }
                                }

                            }

                        }

                    }

                    Item {
                        Layout.fillHeight: true
                    }

                    Text {
                        text: "Hex value"
                        color: Theme.muted
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 10
                    }

                    BloxTextField {
                        id: colourHexField

                        Layout.fillWidth: true
                        text: controller.colourHex
                        onEditingFinished: {
                            if (/^#[0-9a-fA-F]{6}$/.test(text)) {
                                controller.loadPickerColour(text);
                                controller.applyPickerColour(text);
                            }
                        }
                    }

                    BloxButton {
                        visible: controller.colourPickerTarget.length > 0
                        Layout.fillWidth: true
                        text: "Use semantic colour"
                        onClicked: {
                            controller.setOverride(controller.colourPickerTarget, controller.colourPickerKey, "");
                            controller.dismissColourPicker();
                        }
                    }

                }

            }

        }

    }

}
