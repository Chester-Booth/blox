import qs.popouts
import qs.shared
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    property var targetScreen
    property bool open: false
    property bool rendered: false
    property string updateSummary: ""

    signal action(string kind)
    signal close()

    screen: targetScreen
    exclusionMode: ExclusionMode.Ignore
    focusable: true
    aboveWindows: true
    visible: rendered
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    onOpenChanged: {
        if (open)
            rendered = true;
        else
            hideTimer.restart();
    }

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    Timer {
        id: hideTimer

        interval: 260
        repeat: false
        onTriggered: {
            if (!root.open)
                root.rendered = false;

        }
    }

    PowerOverlay {
        anchors.fill: parent
        overlayOpen: root.open
        updateSummary: root.updateSummary
        onAction: (kind) => {
            return root.action(kind);
        }
        onClose: root.close()
    }

}
