import qs.shared
import QtQuick
import Quickshell

Rectangle {
    id: root

    property var item
    property bool menuOpen: false
    readonly property string tooltipTitle: item ? item.tooltipTitle || item.title || item.id || "" : ""
    readonly property string tooltipDescription: item ? item.tooltipDescription || "" : ""
    property bool tooltipReady: false

    readonly property bool tooltipRequested: (trayMouse.containsMouse || activeFocus) && !menuOpen && tooltipTitle.length > 0
    onTooltipRequestedChanged: {
        tooltipReady = false;
        if (tooltipRequested) tooltipDelay.restart();
        else tooltipDelay.stop();
    }
    Timer {
        id: tooltipDelay
        interval: 320
        onTriggered: root.tooltipReady = root.tooltipRequested
    }

    // A separate surface lets a Blox hint extend beyond the narrow bar window.
    PopupWindow {
        id: tooltip
        objectName: "tray-tooltip"
        anchor.item: root
        anchor.rect.x: Theme.barPosition === "left" ? root.width + 8
            : Theme.barPosition === "right" ? -implicitWidth - 8 : (root.width - implicitWidth) / 2
        anchor.rect.y: Theme.barPosition === "top" ? root.height + 8
            : Theme.barPosition === "bottom" ? -implicitHeight - 8 : (root.height - implicitHeight) / 2
        implicitWidth: Math.min(320, Math.ceil(tooltipLabel.implicitWidth) + 2 * Theme.scaledSpacing(7) + 2)
        implicitHeight: tooltipLabel.implicitHeight + 2 * Theme.scaledSpacing(7)
        visible: root.tooltipReady && !root.menuOpen && (trayMouse.containsMouse || root.activeFocus)
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            radius: Theme.scaledRadius(7)
            color: Theme.surfaceAlt
            border.color: Theme.border
            border.width: 1
            Text {
                id: tooltipLabel
                objectName: "tray-tooltip-label"
                x: Theme.scaledSpacing(7)
                y: Theme.scaledSpacing(7)
                width: Math.max(0, tooltip.implicitWidth - 2 * Theme.scaledSpacing(7))
                text: root.tooltipTitle + (root.tooltipDescription.length > 0 && root.tooltipDescription !== root.tooltipTitle
                    ? " " + root.tooltipDescription : "")
                textFormat: Text.PlainText
                color: Theme.foreground
                font.family: Theme.bodyFontFamily
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
        }
    }

    signal openMenu(var item, real centerY)
    signal hovered()
    signal exited()

    activeFocusOnTab: !!item
    Keys.onPressed: event => {
        if (!root.item) return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) root.item.activate();
        else if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) root.openMenu(root.item, root.height / 2);
        else return;
        event.accepted = true;
    }
    border.width: activeFocus ? 1 : 0
    border.color: Theme.blue

    implicitWidth: Theme.buttonSize
    implicitHeight: Theme.buttonSize
    width: implicitWidth
    height: implicitHeight
    radius: Theme.barRadius
    color: trayMouse.containsMouse ? Theme.surfaceAlt : "transparent"
    clip: true

    Image {
        anchors.centerIn: parent
        width: 17
        height: 17
        source: root.item ? root.item.icon : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    MouseArea {
        id: trayMouse

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hovered()
        onExited: root.exited()
        onPressed: (event) => {
            root.tooltipReady = false;
            tooltipDelay.stop();
        }
        onClicked: (event) => {
            if (event.button === Qt.RightButton) {
                root.openMenu(root.item, root.height / 2);
                event.accepted = true;
                return ;
            } else if (event.button === Qt.MiddleButton) {
                root.item.secondaryActivate();
            } else {
                root.item.activate();
            }
        }
    }

}
