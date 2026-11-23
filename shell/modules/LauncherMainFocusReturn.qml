import QtQuick
import Quickshell

Scope {
    id: root

    property var targetController

    signal closeRequested()

    function dismiss() {
        if (targetController)
            targetController.restoreTarget();
        closeRequested();
    }

    function selectDmenu() {
        if (targetController)
            targetController.restoreTarget();
    }
}
