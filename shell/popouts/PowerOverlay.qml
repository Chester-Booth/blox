import "../shared"
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property bool overlayOpen: false
    property string updateSummary: "Check updates"
    property int openAnimationDuration: 900

    signal action(string command)
    signal close()

    color: "transparent"

    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.background, 0.6)
        opacity: root.overlayOpen ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: root.overlayOpen ? 200 : 300
                easing.type: Easing.InSine
            }

        }

    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 160, 820)
        height: Math.min(parent.height - 160, 420)
        spacing: 18

        Text {
            Layout.fillWidth: true
            text: "Power"
            color: Theme.foreground
            opacity: root.overlayOpen ? 1 : 0
            font.family: Theme.bodyFontFamily
            font.pixelSize: 22
            font.bold: true
            horizontalAlignment: Text.AlignHCenter

            Behavior on opacity {
                NumberAnimation {
                    duration: root.openAnimationDuration
                    easing.type: Easing.InCubic
                }

            }

        }

        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 3
            rowSpacing: 12
            columnSpacing: 12

            Repeater {
                model: [{
                    "icon": "󰌾",
                    "label": "Lock",
                    "command": "lock"
                }, {
                    "icon": "󰒲",
                    "label": "Sleep",
                    "command": "sleep"
                }, {
                    "icon": "󰤄",
                    "label": "Hibernate",
                    "command": "hibernate"
                }, {
                    "icon": "󰚰",
                    "label": "Update + shutdown",
                    "command": "update-shutdown",
                    "danger": true
                }, {
                    "icon": "󰜉",
                    "label": "Reboot",
                    "command": "reboot",
                    "danger": true
                }, {
                    "icon": "⏻",
                    "label": "Shut down",
                    "command": "shutdown",
                    "danger": true
                }]

                Rectangle {
                    id: buttonCard

                    function show() {
                        hideAnimation.stop();
                        opacity = 0;
                        scale = 0.96;
                        buttonSlide.y = 18;
                        showAnimation.restart();
                    }

                    function hide() {
                        showAnimation.stop();
                        hideAnimation.restart();
                    }

                    radius: 8
                    color: powerMouse.containsMouse ? Theme.withAlpha(Theme.surfaceAlt, 0.93) : Theme.withAlpha(Theme.surface, 0.87)
                    border.color: modelData.danger ? Theme.red : Theme.surfaceAlt
                    border.width: 1
                    opacity: 0
                    scale: 0.96
                    transformOrigin: Item.Center
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 112
                    Component.onCompleted: {
                        if (root.overlayOpen)
                            show();

                    }

                    Connections {
                        function onOverlayOpenChanged() {
                            if (root.overlayOpen)
                                buttonCard.show();
                            else
                                buttonCard.hide();
                        }

                        target: root
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 8

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.icon
                            color: modelData.danger ? Theme.red : Theme.foreground
                            font.family: Theme.fontFamily
                            font.pixelSize: 32
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.command === "update-shutdown" ? modelData.label + "\n" + root.updateSummary : modelData.label
                            color: Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 13
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                        }

                    }

                    SequentialAnimation {
                        id: showAnimation

                        PauseAnimation {
                            duration: 200 + index * 64
                        }

                        ParallelAnimation {
                            NumberAnimation {
                                target: buttonCard
                                property: "opacity"
                                from: buttonCard.opacity
                                to: 1
                                duration: 150
                                easing.type: Easing.OutCubic
                            }

                            NumberAnimation {
                                target: buttonCard
                                property: "scale"
                                from: buttonCard.scale
                                to: 1
                                duration: 150
                                easing.type: Easing.OutCubic
                            }

                            NumberAnimation {
                                target: buttonSlide
                                property: "y"
                                from: buttonSlide.y
                                to: 0
                                duration: 150
                                easing.type: Easing.OutCubic
                            }

                        }

                    }

                    ParallelAnimation {
                        id: hideAnimation

                        NumberAnimation {
                            target: buttonCard
                            property: "opacity"
                            from: buttonCard.opacity
                            to: 0
                            duration: 110
                            easing.type: Easing.InCubic
                        }

                        NumberAnimation {
                            target: buttonCard
                            property: "scale"
                            from: buttonCard.scale
                            to: 0.96
                            duration: 130
                            easing.type: Easing.InCubic
                        }

                        NumberAnimation {
                            target: buttonSlide
                            property: "y"
                            from: buttonSlide.y
                            to: 18
                            duration: 130
                            easing.type: Easing.InCubic
                        }

                    }

                    MouseArea {
                        id: powerMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.action(modelData.command);
                            root.close();
                        }
                    }

                    transform: Translate {
                        id: buttonSlide

                        y: 18
                    }

                }

            }

        }

    }

}
