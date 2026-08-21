import "../shared"
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

Scope {
    id: root

    required property OsdController controller

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: osdWindow

            required property var modelData
            readonly property bool onLeft: Theme.osdPosition === "top-left" || Theme.osdPosition === "bottom-left"
            readonly property bool onRight: Theme.osdPosition === "top-right" || Theme.osdPosition === "bottom-right"
            readonly property bool onTop: Theme.osdPosition.indexOf("top") >= 0
            readonly property bool onBottom: Theme.osdPosition.indexOf("bottom") >= 0
            readonly property bool horizontallyCentred: !onLeft && !onRight
            readonly property real restingGap: Math.max(0, onTop ? 28 + Theme.osdOffsetY : 28 - Theme.osdOffsetY)

            screen: modelData
            visible: root.controller.rendered
            implicitWidth: 292 + (horizontallyCentred ? 2 * Math.abs(Theme.osdOffsetX) : 0)
            implicitHeight: 72 + restingGap
            exclusiveZone: 0
            focusable: false
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "blox-osd"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors {
                left: onLeft
                right: onRight
                top: onTop
                bottom: onBottom
            }

            margins {
                left: onLeft ? 28 + Theme.osdOffsetX : 0
                right: onRight ? 28 - Theme.osdOffsetX : 0
            }

            Item {
                id: osdPopup

                x: osdWindow.horizontallyCentred ? Math.abs(Theme.osdOffsetX) + Theme.osdOffsetX : 0
                y: osdWindow.onTop ? osdWindow.restingGap : 0
                width: 292
                height: 72
                visible: root.controller.rendered

                Rectangle {
                    id: osdCard

                    anchors.fill: parent
                    radius: 8
                    color: Theme.background
                    border.color: Theme.surfaceAlt
                    border.width: 1
                    opacity: root.controller.showing ? 1 : 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12

                        Text {
                            Layout.preferredWidth: 34
                            horizontalAlignment: Text.AlignHCenter
                            text: root.controller.icon
                            color: root.controller.volumeOverdriven ? Theme.red : root.controller.muted ? Theme.yellow : root.controller.noticeMode ? root.controller.noticeAccent : Theme.foreground
                            font.family: Theme.fontFamily
                            font.pixelSize: 26
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                visible: !root.controller.noticeMode

                                Text {
                                    Layout.fillWidth: true
                                    text: root.controller.label
                                    color: Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 14
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: root.controller.valueText
                                    color: root.controller.volumeOverdriven ? Theme.red : root.controller.muted ? Theme.yellow : Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: 150
                                }

                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                visible: root.controller.noticeMode

                                Text {
                                    Layout.fillWidth: true
                                    text: root.controller.label
                                    color: Theme.foreground
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 14
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.controller.valueText
                                    color: Theme.muted
                                    font.family: Theme.bodyFontFamily
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }

                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 8
                                radius: 4
                                color: Theme.surface
                                visible: !root.controller.segmented

                                Rectangle {
                                    width: Math.round(parent.width * root.controller.fillValue / 100)
                                    height: parent.height
                                    radius: 4
                                    color: root.controller.volumeOverdriven ? Theme.red : root.controller.muted ? Theme.yellow : root.controller.noticeMode ? root.controller.noticeAccent : Theme.blue
                                }

                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 7
                                visible: root.controller.segmented

                                Repeater {
                                    model: root.controller.segments

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 8
                                        radius: 4
                                        color: index < root.controller.activeSegments ? Theme.blue : Theme.surface
                                    }

                                }

                            }

                        }

                    }

                    transform: Translate {
                        y: root.controller.showing ? 0 : osdWindow.onTop ? -osdCard.height - osdWindow.restingGap : osdWindow.height

                        Behavior on y {
                            NumberAnimation {
                                duration: 190
                                easing.type: Easing.OutCubic
                            }

                        }

                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 140
                            easing.type: Easing.OutCubic
                        }

                    }

                }

            }

            // OSD cards are informational only. Keep their input region empty so
            // pointer events always reach the application underneath.
            mask: Region {
            }

        }

    }

}
