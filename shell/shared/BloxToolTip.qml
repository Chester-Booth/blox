import QtQuick
import QtQuick.Controls

Popup {
    id: root

    property bool shown: false
    property string text: ""
    property int delay: 320
    property string preferredPlacement: "auto"
    readonly property var hostWindow: parent ? parent.Window.window : null

    popupType: Popup.Item
    modal: false
    dim: false
    focus: false
    closePolicy: Popup.NoAutoClose
    padding: 7
    width: Math.max(40, Math.min(320, hostWindow ? hostWindow.width - 8 : 320, tooltipLabel.implicitWidth + leftPadding + rightPadding))
    onShownChanged: {
        if (shown) {
            showTimer.restart();
        } else {
            showTimer.stop();
            close();
        }
    }

    Timer {
        id: showTimer

        interval: root.delay
        onTriggered: {
            if (root.shown) {
                const hostWindow = root.hostWindow;
                if (!hostWindow)
                    return ;

                const point = root.parent.mapToItem(null, 0, 0);
                const windowWidth = hostWindow.width;
                const windowHeight = hostWindow.height;
                const topRight = root.preferredPlacement === "top-right";
                const wantedX = topRight ? point.x + root.parent.width + 8 : point.x + (root.parent.width - root.width) / 2;
                const sceneX = Math.max(4, Math.min(windowWidth - root.width - 4, wantedX));
                const below = point.y + root.parent.height + 6;
                const wantedY = topRight ? point.y - root.height - 8 : below + root.height <= windowHeight - 4 ? below : point.y - root.height - 6;
                const sceneY = Math.max(4, Math.min(windowHeight - root.height - 4, wantedY));
                root.x = sceneX - point.x;
                root.y = sceneY - point.y;
                root.open();
            }
        }
    }

    contentItem: Text {
        id: tooltipLabel

        width: root.width - root.leftPadding - root.rightPadding
        text: root.text
        color: Theme.foreground
        font.family: Theme.bodyFontFamily
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    background: Rectangle {
        radius: 7
        color: Theme.surfaceAlt
        border.color: Theme.border
        border.width: 1
    }

}
