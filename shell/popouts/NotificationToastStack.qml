import qs.shared
import QtQuick
import Quickshell.Services.Notifications

Item {
    id: root

    property var toasts: []
    property var activationLabel: null
    property string position: "bottom-right"
    readonly property bool entersFromLeft: position === "top-left" || position === "bottom-left"
    readonly property bool entersVertically: position === "centre-top" || position === "centre-bottom"
    readonly property real entranceX: entersVertically ? 0 : entersFromLeft ? -dismissTravel : dismissTravel
    readonly property real entranceY: !entersVertically ? 0 : position === "centre-top" ? -120 : 120
    readonly property int toastWidth: 330
    readonly property int sidePadding: 12
    readonly property int dismissTravel: toastWidth + sidePadding
    property var animatedToastIds: ({
    })

    signal dismiss(var notification, bool closeNotification)
    signal activate(var notification)
    signal actionInvoked(var notification)

    function takeEntranceAnimation(toastId) {
        if (animatedToastIds[toastId] === true)
            return false;

        animatedToastIds[toastId] = true;
        return true;
    }

    function pruneEntranceHistory() {
        const retained = {
        };
        const current = toasts || [];
        for (let i = 0; i < current.length; i++) {
            const toastId = current[i].toastId;
            if (animatedToastIds[toastId] === true)
                retained[toastId] = true;

        }
        animatedToastIds = retained;
    }

    // Keep the item's bounds identical to the visible card.  The toasts may
    // travel beyond those bounds while animating because this item lives in a
    // full-screen layer surface.  Including that travel area in our width
    // offsets left- and centre-anchored cards even though their anchor is
    // technically correct.
    width: toastWidth
    height: implicitHeight
    implicitHeight: toastColumn.implicitHeight
    onToastsChanged: pruneEntranceHistory()

    Column {
        id: toastColumn

        x: 0
        width: root.toastWidth
        spacing: Theme.scaledSpacing(8)

        Repeater {
            model: root.toasts

            Rectangle {
                id: toast

                property var notification: modelData.notification
                property bool dismissing: false
                property bool dragged: false
                property bool closeNotificationOnDismiss: false
                property bool animateHorizontalMovement: true
                property int remainingLifetime: 0
                property double expiryStartedAt: 0
                readonly property string clickTooltip: root.activationLabel ? root.activationLabel(notification) : ""

                function startExpiry(duration) {
                    remainingLifetime = Math.max(1, duration);
                    expiryTimer.interval = remainingLifetime;
                    expiryStartedAt = Date.now();
                    expiryTimer.restart();
                }

                function pauseExpiry() {
                    if (!expiryTimer.running)
                        return ;

                    remainingLifetime = Math.max(1, remainingLifetime - (Date.now() - expiryStartedAt));
                    expiryTimer.stop();
                }

                function resumeExpiry() {
                    if (!dismissing && !expiryTimer.running)
                        startExpiry(remainingLifetime);

                }

                function finishDismiss(closeNotification) {
                    if (dismissing)
                        return ;

                    expiryTimer.stop();
                    closeNotificationOnDismiss = closeNotification;
                    dismissing = true;
                    x = root.entranceX;
                    y = root.entranceY;
                    dismissTimer.restart();
                }

                x: root.entranceX
                y: root.entranceY
                width: root.toastWidth
                height: toastBody.implicitHeight + 18
                opacity: dismissing ? 0 : 1
                radius: Theme.scaledRadius(8)
                color: Theme.surface
                border.color: notification && notification.urgency === NotificationUrgency.Critical ? Theme.red : Theme.surfaceAlt
                border.width: 1
                Component.onCompleted: {
                    animateHorizontalMovement = root.takeEntranceAnimation(modelData.toastId);
                    const fullLifetime = Math.max(3500, modelData.timeout || 6000);
                    const remainingLifetime = modelData.expiresAt ? Math.max(1, modelData.expiresAt - Date.now()) : fullLifetime;
                    toast.startExpiry(animateHorizontalMovement ? fullLifetime : remainingLifetime);
                    x = 0;
                    y = 0;
                    if (!animateHorizontalMovement)
                        Qt.callLater(() => {
                        return animateHorizontalMovement = true;
                    });

                }

                Timer {
                    id: dismissTimer

                    interval: 185
                    repeat: false
                    onTriggered: root.dismiss(toast.notification, toast.closeNotificationOnDismiss)
                }

                Timer {
                    id: expiryTimer

                    repeat: false
                    onTriggered: toast.finishDismiss(false)
                }

                Item {
                    id: tooltipAnchor

                    x: toastHover.point.position.x
                    y: toastHover.point.position.y
                    width: 1
                    height: 1

                    BloxToolTip {
                        shown: toastHover.hovered && toast.clickTooltip.length > 0 && !toast.dismissing
                        text: toast.clickTooltip
                        preferredPlacement: "top-right"
                    }

                }

                HoverHandler {
                    id: toastHover

                    cursorShape: toast.clickTooltip.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onHoveredChanged: {
                        if (hovered)
                            toast.pauseExpiry();
                        else
                            toast.resumeExpiry();
                    }
                }

                NotificationContent {
                    id: toastBody

                    z: 1
                    anchors.fill: parent
                    anchors.margins: Theme.scaledSpacing(9)
                    notification: toast.notification
                    meta: toast.notification && toast.notification.appName ? toast.notification.appName + " • now" : "notification • now"
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
                    anchors.topMargin: Theme.scaledSpacing(9)
                    anchors.rightMargin: Theme.scaledSpacing(9)
                    z: 4
                    width: 24
                    height: 24
                    radius: Theme.scaledRadius(6)
                    color: closeMouse.containsMouse ? Theme.surfaceAlt : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "󰅖"
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                    }

                }

                MouseArea {
                    id: toastMouse

                    anchors.fill: parent
                    anchors.rightMargin: Theme.scaledSpacing(42)
                    z: 0
                    acceptedButtons: Qt.LeftButton
                    drag.target: toast
                    drag.axis: Drag.XAxis
                    drag.minimumX: 0
                    drag.maximumX: root.dismissTravel
                    propagateComposedEvents: true
                    onPressed: {
                        toast.dragged = false;
                    }
                    onPositionChanged: (mouse) => {
                        toast.dragged = toast.dragged || Math.abs(toast.x) > 8;
                    }
                    onReleased: {
                        if (toast.x > 28)
                            toast.finishDismiss(true);
                        else
                            toast.x = 0;
                    }
                    onCanceled: {
                        toast.x = 0;
                    }
                    onClicked: (mouse) => {
                        if (toast.dragged) {
                            mouse.accepted = true;
                            return ;
                        }
                        root.activate(toast.notification);
                    }
                }

                MouseArea {
                    id: closeMouse

                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: Theme.scaledSpacing(6)
                    anchors.rightMargin: Theme.scaledSpacing(6)
                    width: 36
                    height: 36
                    z: 5
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: toast.finishDismiss(true)
                }

                Behavior on x {
                    enabled: toast.animateHorizontalMovement && !toastMouse.drag.active

                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutCubic
                    }

                }

                Behavior on y {
                    enabled: toast.animateHorizontalMovement && !toastMouse.drag.active

                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutCubic
                    }

                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: 160
                        easing.type: Easing.OutCubic
                    }

                }

            }

        }

    }

}
