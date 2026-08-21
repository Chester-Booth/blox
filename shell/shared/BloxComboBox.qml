import QtQuick
import QtQuick.Controls

Rectangle {
    id: root

    property var model: []
    property int currentIndex: 0
    readonly property string currentText: currentIndex >= 0 && currentIndex < model.length ? String(model[currentIndex]) : ""
    readonly property bool hovered: hover.hovered

    signal activated(int index, string text)

    function choose(index) {
        if (index < 0 || index >= model.length)
            return ;

        activated(index, String(model[index]));
        popup.close();
        forceActiveFocus();
    }

    function openPopup() {
        if (!enabled || model.length === 0)
            return ;

        popup.open();
    }

    function moveHighlight(delta) {
        if (!popup.visible)
            openPopup();

        const start = list.currentIndex >= 0 ? list.currentIndex : Math.max(0, currentIndex);
        list.currentIndex = Math.max(0, Math.min(model.length - 1, start + delta));
        list.positionViewAtIndex(list.currentIndex, ListView.Contain);
    }

    implicitHeight: 38
    implicitWidth: 132
    radius: 9
    color: pointer.pressed || popup.visible ? Theme.surfaceAlt : hovered ? Theme.withAlpha(Theme.surfaceAlt, 0.72) : Theme.background
    border.color: activeFocus || popup.visible ? Theme.blue : Theme.border
    border.width: activeFocus || popup.visible ? 2 : 1
    activeFocusOnTab: enabled
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openPopup();
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            root.moveHighlight(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
            root.moveHighlight(-1);
            event.accepted = true;
        }
    }
    onVisibleChanged: {
        if (!visible)
            popup.close();

    }

    Text {
        anchors.left: parent.left
        anchors.right: indicator.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 11
        anchors.rightMargin: 8
        text: root.currentText
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 12
        elide: Text.ElideRight
    }

    Canvas {
        id: indicator

        property color strokeColour: root.hovered || popup.visible ? Theme.foreground : Theme.muted

        anchors.right: parent.right
        anchors.rightMargin: 11
        anchors.verticalCenter: parent.verticalCenter
        width: 18
        height: 18
        rotation: popup.visible ? 180 : 0
        onStrokeColourChanged: requestPaint()
        onPaint: {
            const context = getContext("2d");
            context.reset();
            context.strokeStyle = strokeColour;
            context.lineWidth = 2.2;
            context.lineCap = "round";
            context.lineJoin = "round";
            context.beginPath();
            context.moveTo(3.5, 6.5);
            context.lineTo(9, 11.5);
            context.lineTo(14.5, 6.5);
            context.stroke();
        }
    }

    HoverHandler {
        id: hover

        cursorShape: Qt.PointingHandCursor
    }

    MouseArea {
        id: pointer

        anchors.fill: parent
        enabled: root.enabled
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openPopup()
    }

    Popup {
        id: popup

        popupType: Popup.Item
        // Selection popups must own the pointer grab until the triggering
        // event is complete. Without a modal overlay, the release can reach a
        // control behind an Item popup after the popup closes.
        modal: true
        dim: false
        y: root.height + 5
        width: root.width
        height: Math.min(260, list.contentHeight + 8)
        padding: 4
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: {
            list.currentIndex = Math.max(0, Math.min(root.model.length - 1, root.currentIndex));
            list.positionViewAtIndex(list.currentIndex, ListView.Contain);
            list.forceActiveFocus();
        }
        onClosed: root.forceActiveFocus()

        contentItem: ListView {
            id: list

            clip: true
            model: root.model
            currentIndex: -1
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Down) {
                    root.moveHighlight(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    root.moveHighlight(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.choose(currentIndex);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    popup.close();
                    event.accepted = true;
                }
            }

            delegate: Rectangle {
                required property var modelData
                required property int index

                width: list.width
                height: 36
                radius: 7
                color: optionHover.hovered || index === list.currentIndex || index === root.currentIndex ? Theme.surfaceAlt : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 10
                    text: modelData
                    color: index === root.currentIndex ? Theme.blue : Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                HoverHandler {
                    id: optionHover

                    cursorShape: Qt.PointingHandCursor
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: list.currentIndex = index
                    onClicked: root.choose(index)
                }

            }

        }

        background: Rectangle {
            radius: 9
            color: Theme.surface
            border.color: Theme.border
        }

    }

}
