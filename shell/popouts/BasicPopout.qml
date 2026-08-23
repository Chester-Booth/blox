import "../shared"
import QtQuick

Rectangle {
    id: root

    property string title: ""
    property string subtitle: ""
    property string body: ""
    property string statusError: ""
    property var actions: []
    property string currentId: ""
    property string headerActionIcon: ""
    property string headerActionCommand: ""
    property string headerStatus: ""

    signal action(string command, bool keepOpen)

    width: 340
    height: Math.min(520, Math.max(root.title === "Awake" ? 110 : 140, content.implicitHeight + 28))
    radius: Theme.scaledRadius(8)
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1

    Item {
        id: content

        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(12)
        implicitHeight: headerRow.height + bodyText.implicitHeight + (root.title === "Awake" ? awakeSlider.height + 6 : actionFlow.implicitHeight + 20)

        Item {
            id: headerRow

            width: parent.width
            anchors.top: parent.top
            height: Math.max(22, titleBlock.implicitHeight)

            Text {
                id: titleIcon

                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.title === "Updates" ? "󰧠" : root.title === "Awake" ? "󰅶" : "󰍹"
                color: root.title === "Awake" ? Theme.yellow : Theme.blue
                font.family: Theme.fontFamily
                font.pixelSize: 18
            }

            Column {
                id: titleBlock

                anchors.left: titleIcon.right
                anchors.leftMargin: Theme.scaledSpacing(8)
                anchors.right: headerAction.left
                anchors.rightMargin: headerAction.visible || headerStatusText.visible ? Theme.scaledSpacing(8) : 0
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.scaledSpacing(1)

                Text {
                    width: parent.width
                    text: root.title
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 16
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    visible: root.subtitle.length > 0
                    text: root.subtitle
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

            }

            Rectangle {
                id: headerAction

                anchors.right: headerStatusText.visible ? headerStatusText.left : parent.right
                anchors.rightMargin: visible && headerStatusText.visible ? Theme.scaledSpacing(8) : 0
                anchors.verticalCenter: parent.verticalCenter
                visible: root.headerActionCommand.length > 0
                width: visible ? 28 : 0
                height: 28
                radius: Theme.scaledRadius(6)
                color: headerActionMouse.containsMouse ? Theme.surfaceAlt : Theme.surface
                border.color: Theme.surfaceAlt
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: root.headerActionIcon
                    color: Theme.foreground
                    font.family: Theme.fontFamily
                    font.pixelSize: 14
                }

                MouseArea {
                    id: headerActionMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.action(root.headerActionCommand, true)
                }

            }

            Text {
                id: headerStatusText

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.headerStatus.length > 0
                text: root.headerStatus
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: root.headerStatus === "∞" ? 20 : 12
                font.bold: true
            }

        }

        Text {
            id: bodyText

            anchors.top: headerRow.bottom
            anchors.topMargin: Theme.scaledSpacing(8)
            width: parent.width
            text: root.statusError.length > 0 ? "Status error: " + root.statusError + (root.body.length > 0 ? "\n\n" + root.body : "") : root.body
            color: root.statusError.length > 0 ? Theme.red : Theme.foreground
            font.family: Theme.bodyFontFamily
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }

        Flow {
            id: actionFlow

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: parent.width
            spacing: Theme.scaledSpacing(8)
            visible: root.title !== "Awake"

            Repeater {
                model: root.actions

                Rectangle {
                    width: root.title === "Updates" ? Math.floor((parent.width - 8) / 2) : Math.max(96, actionContent.implicitWidth + 22)
                    height: 34
                    radius: Theme.scaledRadius(7)
                    color: actionMouse.containsMouse ? Theme.surfaceAlt : Theme.surface
                    border.color: modelData.danger ? Theme.red : Theme.surfaceAlt
                    border.width: 1

                    Row {
                        id: actionContent

                        anchors.centerIn: parent
                        spacing: Theme.scaledSpacing(7)

                        Text {
                            visible: !!modelData.icon
                            text: modelData.icon || ""
                            color: modelData.danger ? Theme.red : Theme.foreground
                            font.family: Theme.fontFamily
                            font.pixelSize: 13
                        }

                        Text {
                            id: actionLabel

                            text: modelData.label || ""
                            color: modelData.danger ? Theme.red : Theme.foreground
                            font.family: Theme.bodyFontFamily
                            font.pixelSize: 12
                            font.bold: true
                        }

                    }

                    MouseArea {
                        id: actionMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const label = (modelData.label || "").toLowerCase();
                            const keepOpen = !!modelData.keepOpen || label.indexOf("cycle") >= 0 || label.indexOf(" up") >= 0 || label.indexOf(" down") >= 0;
                            root.action(modelData.command || "", keepOpen);
                        }
                    }

                }

            }

        }

        PillSelector {
            id: awakeSlider

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.title === "Awake"
            title: "Duration"
            currentId: root.currentId || "off"
            options: root.actions
            optimistic: true
            onSelected: (id) => {
                for (let i = 0; i < root.actions.length; i++) {
                    if ((root.actions[i].id || "") === id) {
                        root.action(root.actions[i].command || "", true);
                        return ;
                    }
                }
            }
        }

    }

}
