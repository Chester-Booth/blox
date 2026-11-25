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
    property var actions: null
    property bool pendingForceReopen: false
    property bool preservingAlertOnReopen: false

    signal action(string kind)
    signal reopen()
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
        if (open) {
            rendered = true;
            if (root.actions) {
                if (root.preservingAlertOnReopen) {
                    root.preservingAlertOnReopen = false;
                } else if (typeof root.actions.clearPowerError === "function") {
                    root.actions.clearPowerError();
                }
                if (typeof root.actions.refreshPowerBlockers === "function")
                    root.actions.refreshPowerBlockers();
            }
        } else {
            if (!root.pendingForceReopen && root.actions && typeof root.actions.clearPowerError === "function")
                root.actions.clearPowerError();
            hideTimer.restart();
        }
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

    Connections {
        target: root.actions
        function onPowerFinished(success) {
            if (success) {
                root.pendingForceReopen = false;
                if (root.open)
                    root.close();
            } else if (root.pendingForceReopen) {
                root.pendingForceReopen = false;
                root.preservingAlertOnReopen = true;
                root.reopen();
            }
        }
    }

    PowerOverlay {
        anchors.fill: parent
        overlayOpen: root.open
        updateSummary: root.updateSummary
        actionBusy: root.actions ? root.actions.powerBusy : false
        actionError: root.actions ? root.actions.powerError : ""
        actionAlert: root.actions && root.actions.powerAlert !== undefined ? root.actions.powerAlert : null
        powerBlockers: root.actions && root.actions.powerBlockers !== undefined ? root.actions.powerBlockers : ({"sleep": [], "shutdown": [], "micro": []})
        onAction: (kind) => {
            if (kind.indexOf("force:") === 0) {
                // Close the overlay before running -i so any polkit dialog is never hidden beneath it.
                root.pendingForceReopen = true;
                root.close();
                root.action(kind);
                return;
            }
            if (kind.indexOf("focus-special:") === 0) {
                if (root.actions && typeof root.actions.clearPowerError === "function")
                    root.actions.clearPowerError();
                root.close();
                root.action(kind);
                return;
            }
            root.pendingForceReopen = false;
            root.action(kind);
        }
        onDismissAlert: {
            if (root.actions && typeof root.actions.clearPowerError === "function")
                root.actions.clearPowerError();
        }
        onClose: root.close()
    }

}
