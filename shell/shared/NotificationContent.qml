import Qt5Compat.GraphicalEffects
import QtQuick
import Quickshell

Column {
    id: root

    property var notification
    property string meta: notification && notification.appName ? notification.appName : ""
    property int maximumBodyLineCount: 4
    property int headerRightPadding: 0
    property var actionItems: []
    readonly property bool hasActions: actionItems.length > 0
    readonly property string rawNotificationImage: notification && notification.image ? String(notification.image) : ""
    readonly property string notificationImageIconName: imageIconName(rawNotificationImage)
    readonly property string notificationImage: resolvedNotificationImage()
    readonly property bool hasImage: notificationImage.length > 0
    readonly property bool tintNotificationImage: notificationImageIconName.endsWith("-symbolic")
    readonly property string rawAppIcon: notification && notification.appIcon ? String(notification.appIcon) : ""
    readonly property string appIconName: resolvedAppIconName()
    readonly property string appIcon: appIconName.length > 0 ? Quickshell.iconPath(appIconName, true) : ""
    readonly property bool tintAppIcon: appIconName.endsWith("-symbolic") || appIconName.endsWith("-symbolic.svg")

    signal actionInvoked(var notification)

    function bluetoothBatteryIcon() {
        const match = String(notification && notification.body || "").match(/(\d{1,3})\s*%/);
        if (!match)
            return "battery-symbolic";

        const percentage = Math.max(0, Math.min(100, Number(match[1])));
        const level = Math.round(percentage / 10) * 10;
        return "battery-level-" + level + "-symbolic";
    }

    function resolvedAppIconName() {
        return remapIconName(rawAppIcon);
    }

    function remapIconName(iconName) {
        if (iconName === "battery")
            return bluetoothBatteryIcon();

        if (iconName === "audio-headset" || iconName === "audio-headphones")
            return iconName + "-symbolic";

        return iconName;
    }

    function imageIconName(imageSource) {
        const prefix = "image://icon/";
        if (!imageSource.startsWith(prefix))
            return "";

        return remapIconName(imageSource.substring(prefix.length));
    }

    function resolvedNotificationImage() {
        if (notificationImageIconName.length === 0)
            return rawNotificationImage;

        return Quickshell.iconPath(notificationImageIconName, true);
    }

    function refreshActions() {
        const next = [];
        const actions = notification ? notification.actions : null;
        if (actions) {
            for (let i = 0; i < actions.length; i++) {
                // The default action belongs to the card itself. Showing it as
                // a second button is what gives Discord notifications a
                // redundant "View" button.
                if (actions[i].identifier !== "default" && String(actions[i].text || "").trim().length > 0)
                    next.push(actions[i]);

            }
        }
        actionItems = next;
    }

    function actionIcon(action) {
        if (!notification || !notification.hasActionIcons || !action || !action.identifier)
            return "";

        return Quickshell.iconPath(action.identifier, true);
    }

    spacing: Theme.scaledSpacing(6)
    onNotificationChanged: refreshActions()
    Component.onCompleted: refreshActions()

    Connections {
        function onActionsChanged() {
            root.refreshActions();
        }

        target: root.notification
        ignoreUnknownSignals: true
    }

    Row {
        id: notificationRow

        width: parent.width
        spacing: notificationThumbnail.visible ? Theme.scaledSpacing(8) : 0

        Image {
            id: notificationThumbnail

            visible: root.hasImage
            width: visible ? 72 : 0
            height: visible ? 72 : 0
            source: root.notificationImage
            sourceSize.width: 144
            sourceSize.height: 144
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            layer.enabled: root.tintNotificationImage

            layer.effect: ColorOverlay {
                color: Theme.foreground
            }

        }

        Column {
            width: parent.width - notificationThumbnail.width - parent.spacing
            spacing: Theme.scaledSpacing(6)

            Row {
                width: parent.width - root.headerRightPadding
                spacing: appIconSlot.visible ? Theme.scaledSpacing(8) : 0

                Item {
                    id: appIconSlot

                    visible: root.appIcon.length > 0
                    width: visible ? 30 : 0
                    height: 30

                    Image {
                        id: appIconImage

                        anchors.fill: parent
                        source: root.appIcon
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        mipmap: true
                        layer.enabled: root.tintAppIcon

                        layer.effect: ColorOverlay {
                            color: Theme.foreground
                        }

                    }

                }

                NotificationHeader {
                    width: parent.width - appIconSlot.width - parent.spacing
                    summary: root.notification ? root.notification.summary : ""
                    meta: root.meta
                }

            }

            NotificationBody {
                width: parent.width
                body: root.notification ? root.notification.body : ""
                opacity: 0.86
                maximumLineCount: root.maximumBodyLineCount
            }

        }

    }

    Flow {
        width: parent.width
        visible: root.hasActions
        spacing: Theme.scaledSpacing(6)

        Repeater {
            model: root.actionItems

            Rectangle {
                readonly property string iconSource: root.actionIcon(modelData)

                width: Math.min(parent.width, Math.max(76, actionRow.implicitWidth + 20))
                height: 28
                radius: Theme.scaledRadius(7)
                color: actionMouse.containsMouse ? Theme.surfaceAlt : Theme.background
                border.color: Theme.surfaceAlt
                border.width: 1

                Row {
                    id: actionRow

                    anchors.centerIn: parent
                    spacing: actionIcon.visible ? Theme.scaledSpacing(5) : 0

                    Image {
                        id: actionIcon

                        width: visible ? 14 : 0
                        height: 14
                        visible: parent.parent.iconSource.length > 0
                        source: parent.parent.iconSource
                        fillMode: Image.PreserveAspectFit
                    }

                    Text {
                        id: actionLabel

                        text: modelData.text || ""
                        color: Theme.foreground
                        font.family: Theme.bodyFontFamily
                        font.pixelSize: 11
                        font.bold: true
                    }

                }

                MouseArea {
                    id: actionMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.actionInvoked(root.notification);
                        modelData.invoke();
                    }
                }

            }

        }

    }

}
