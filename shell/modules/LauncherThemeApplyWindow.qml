import qs.shared
import qs.services
import QtQuick
import QtQuick.Controls
import Quickshell

// Launcher quick Apply stays a separate window and uses the Settings flow.
FloatingWindow {
    id: root
    readonly property Item captureItem: frame
    required property LauncherMainController controller
    property var targetScreen
    title: "Blox Theme Application"
    implicitWidth: 770
    implicitHeight: 680
    minimumSize: Qt.size(680, 600)
    screen: targetScreen
    visible: SettingsApplyController.quickWindowOpen
    color: "transparent"
    onClosed: {
        if (SettingsApplyController.busy) Qt.callLater(() => root.visible = Qt.binding(() => SettingsApplyController.quickWindowOpen));
        else SettingsApplyController.finishApply();
    }
    Timer {
        interval: 100
        running: root.visible && Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE").length > 0
            && Quickshell.env("QT_QPA_PLATFORM") !== "offscreen"
        onTriggered: Quickshell.execDetached(["python3", decodeURIComponent(String(Qt.resolvedUrl("../scripts/place_settings_window.py")).replace(/^file:\/\//, "")),
            root.title, String(Quickshell.processId), String(root.implicitWidth), String(root.implicitHeight)])
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        anchors.margins: Theme.scaledSpacing(1)
        color: Theme.background
        border.color: Theme.border
        radius: Theme.scaledRadius(9)
        clip: true
        Flickable {
            id: scroll
            anchors.fill: parent
            anchors.margins: Theme.scaledSpacing(28)
            clip: true
            contentWidth: width
            contentHeight: page.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            BloxWheelHandler { flickable: scroll }
            ScrollBar.vertical: BloxScrollBar {}
            SettingsApplyReviewPage {
                id: page
                width: scroll.width - Theme.scaledSpacing(20)
                windowOwner: SettingsApplyController.windowOwner
                flowState: SettingsApplyController
                scrollHost: scroll
            }
        }
        Keys.onEscapePressed: event => {
            if (!SettingsApplyController.busy) SettingsApplyController.finishApply();
            event.accepted = true;
        }
    }
}
