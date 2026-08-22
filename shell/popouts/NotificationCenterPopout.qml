import "../shared"
import QtQuick
import QtQuick.Controls
import Quickshell.Services.Notifications

Rectangle {
    id: root

    property var notifications: []
    property real maxPopoutHeight: 720
    property bool dnd: false
    property int clearAnimationRevision: 0
    property double nowMs: Date.now()
    readonly property int notificationListChromeHeight: 240

    signal toggleDnd()
    signal activate(var notification)
    signal actionInvoked(var notification)

    function orderedNotifications() {
        const items = root.notifications ? root.notifications.slice() : [];
        return items.reverse();
    }

    function receivedAt(notification) {
        return notification && notification.bloxReceivedAt ? notification.bloxReceivedAt : root.nowMs;
    }

    function ageText(notification) {
        const elapsed = Math.max(0, root.nowMs - root.receivedAt(notification));
        const seconds = Math.floor(elapsed / 1000);
        if (seconds < 45)
            return "now";

        const minutes = Math.floor(seconds / 60);
        if (minutes < 60)
            return minutes + "m ago";

        const hours = Math.floor(minutes / 60);
        if (hours < 24)
            return hours + "h ago";

        const days = Math.floor(hours / 24);
        return days + "d ago";
    }

    function notificationMeta(notification) {
        const app = notification && notification.appName ? notification.appName : "notification";
        return app + " • " + root.ageText(notification);
    }

    width: 360
    height: Math.min(root.maxPopoutHeight, Math.max(220, content.implicitHeight + 26))
    radius: 8
    color: Theme.background
    border.color: Theme.surfaceAlt
    border.width: 1

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    Column {
        id: content

        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        Row {
            width: parent.width
            height: 34
            spacing: 8

            Item {
                width: 22
                height: parent.height

                Text {
                    anchors.centerIn: parent
                    text: root.dnd ? "󰂛" : "󰂚"
                    color: root.dnd ? Theme.yellow : Theme.blue
                    font.family: Theme.fontFamily
                    font.pixelSize: 18
                }

            }

            Column {
                width: parent.width - clearButton.width - dndSwitch.width - 46
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: "Notifications"
                    color: Theme.foreground
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 16
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: root.notifications.length === 1 ? "1 notification" : root.notifications.length + " notifications"
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

            }

            PillSelector {
                id: dndSwitch

                width: 112
                height: 32
                showHeader: false
                currentId: root.dnd ? "dnd" : "normal"
                selectedAccent: Theme.yellow
                options: [{
                    "id": "normal",
                    "icon": "󰂜",
                    "label": "Notifications"
                }, {
                    "id": "dnd",
                    "icon": "󰂛",
                    "label": "Do not disturb"
                }]
                onSelected: (id) => {
                    if (id !== currentId)
                        root.toggleDnd();

                }
            }

            Rectangle {
                id: clearButton

                width: 30
                height: 30
                radius: 7
                color: clearMouse.containsMouse ? Theme.surfaceAlt : Theme.surface
                border.color: Theme.surfaceAlt
                border.width: 1
                opacity: root.notifications.length > 0 ? 1 : 0.45

                Text {
                    anchors.fill: parent
                    text: "󰆴"
                    color: Theme.foreground
                    font.family: Theme.fontFamily
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                MouseArea {
                    id: clearMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: root.notifications.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        if (root.notifications.length > 0)
                            root.clearAnimationRevision++;

                    }
                }

            }

        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.withAlpha(Theme.foreground, 0.08)
        }

        Flickable {
            id: notificationList

            readonly property bool needsScrollbar: listContent.implicitHeight > height
            readonly property int scrollbarGutter: 16
            property int bottomScrollPadding: needsScrollbar ? 32 : 0

            width: parent.width
            height: Math.min(Math.max(120, root.maxPopoutHeight - root.notificationListChromeHeight), Math.max(90, listContent.implicitHeight))
            contentWidth: width
            contentHeight: listContent.implicitHeight + bottomScrollPadding
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: (event) => {
                    const pixelDelta = event.pixelDelta.y || 0;
                    const angleDelta = event.angleDelta.y || 0;
                    const delta = pixelDelta !== 0 ? pixelDelta : angleDelta / 2;
                    const maximumContentY = Math.max(notificationList.originY, notificationList.originY + notificationList.contentHeight - notificationList.height);
                    notificationList.contentY = Math.max(notificationList.originY, Math.min(maximumContentY, notificationList.contentY - delta * 4));
                    event.accepted = true;
                }
            }

            Column {
                id: listContent

                width: notificationList.width - (notificationList.needsScrollbar ? notificationList.scrollbarGutter : 0)
                spacing: 8

                Text {
                    width: parent.width
                    visible: root.notifications.length === 0
                    text: "No notifications"
                    color: Theme.muted
                    font.family: Theme.bodyFontFamily
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    topPadding: 22
                    bottomPadding: 22
                }

                Repeater {
                    model: root.orderedNotifications()

                    NotificationCard {
                        width: parent.width
                        notification: modelData
                        clearRevision: root.clearAnimationRevision
                    }

                }

            }

            ScrollBar.vertical: ScrollBar {
                id: notificationScrollbar

                width: 8
                policy: notificationList.needsScrollbar ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                interactive: true

                background: Rectangle {
                    implicitWidth: 8
                    radius: 999
                    color: notificationScrollbar.hovered || notificationScrollbar.pressed ? Theme.withAlpha(Theme.foreground, 0.09) : Theme.withAlpha(Theme.foreground, 0.04)
                }

                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: 999
                    color: notificationScrollbar.pressed ? Theme.blue : notificationScrollbar.hovered ? Theme.foreground : Theme.surfaceAlt

                    Behavior on color {
                        ColorAnimation {
                            duration: 110
                            easing.type: Easing.OutCubic
                        }

                    }

                }

            }

        }

    }

    component NotificationCard: Rectangle {
        id: card

        property var notification
        property int clearRevision: 0
        property int seenClearRevision: 0
        property bool removing: false

        function startRemove() {
            if (removing)
                return ;

            removing = true;
            removeTimer.restart();
        }

        height: bodyColumn.implicitHeight + 18
        x: removing ? width * 0.18 : 0
        scale: removing ? 0.985 : 1
        opacity: removing ? 0 : 1
        transformOrigin: Item.Right
        radius: 8
        color: Theme.surface
        border.color: notification && notification.urgency === NotificationUrgency.Critical ? Theme.red : Theme.surfaceAlt
        border.width: 1
        onClearRevisionChanged: {
            if (clearRevision === seenClearRevision)
                return ;

            seenClearRevision = clearRevision;
            startRemove();
        }
        Component.onCompleted: seenClearRevision = clearRevision

        Timer {
            id: removeTimer

            interval: 150
            repeat: false
            onTriggered: {
                if (card.notification)
                    card.notification.dismiss();

            }
        }

        MouseArea {
            anchors.fill: parent
            z: 0
            acceptedButtons: Qt.LeftButton
            onClicked: root.activate(card.notification)
        }

        NotificationContent {
            id: bodyColumn

            z: 1
            anchors.fill: parent
            anchors.margins: 9
            notification: card.notification
            meta: root.notificationMeta(card.notification)
            maximumBodyLineCount: 4
            headerRightPadding: 32
            onActionInvoked: (notification) => {
                return root.actionInvoked(notification);
            }
        }

        Rectangle {
            id: closeButton

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 9
            anchors.rightMargin: 9
            z: 4
            width: 24
            height: 24
            radius: 6
            color: closeMouse.containsMouse ? Theme.surfaceAlt : "transparent"

            Text {
                anchors.centerIn: parent
                text: "󰅖"
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: 12
            }

            MouseArea {
                id: closeMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (card.notification)
                        card.startRemove();

                }
            }

        }

        Behavior on opacity {
            NumberAnimation {
                duration: 150
                easing.type: Easing.OutCubic
            }

        }

        Behavior on x {
            NumberAnimation {
                duration: 150
                easing.type: Easing.OutCubic
            }

        }

        Behavior on scale {
            NumberAnimation {
                duration: 150
                easing.type: Easing.OutCubic
            }

        }

    }

}
