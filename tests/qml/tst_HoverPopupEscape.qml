import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/shared" as Shared
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "HoverPopupEscape"
    when: windowShown

    property var hostWindow: null

    Component {
        id: popupOwner

        Window {
            id: host

            width: 320
            height: 240
            visible: true

            Services.BarSurfaceController {
                id: surfaceController

                objectName: "bar-surface-controller"
            }

            Shared.HoverPopupWindow {
                id: popup

                objectName: "keyboard-popup"
                anchorWindow: host
                contentWidth: 160
                contentHeight: 120
                open: surfaceController.openPanel === "calendar"
                persistentKeyboardFocus: open && surfaceController.keyboardPanel === "calendar"
                onDismissRequested: surfaceController.closePanel()

                Rectangle {
                    objectName: "popup-tab-target"
                    width: 120
                    height: 80
                    activeFocusOnTab: true
                }
            }
        }
    }

    function init() {
        hostWindow = popupOwner.createObject(testCase);
        verify(hostWindow);
        hostWindow.requestActivate();
        tryCompare(hostWindow, "visible", true);
        tryCompare(hostWindow, "active", true);
        const controller = findChild(hostWindow, "bar-surface-controller");
        verify(controller);
        verify(controller.openKeyboardPanel("calendar"));
        tryCompare(findChild(hostWindow, "keyboard-popup"), "visible", true);
    }

    function cleanup() {
        if (hostWindow) {
            hostWindow.close();
            hostWindow.destroy();
            hostWindow = null;
        }
    }

    function test_escape_signal_closes_the_popup_owner() {
        const popup = findChild(hostWindow, "keyboard-popup");
        const target = findChild(popup, "popup-tab-target");
        const controller = findChild(hostWindow, "bar-surface-controller");
        verify(popup);
        verify(target);
        verify(controller);
        compare(controller.openPanel, "calendar");

        target.forceActiveFocus();
        tryCompare(target, "activeFocus", true);
        hostWindow.requestActivate();
        tryCompare(hostWindow, "active", true);
        keyClick(Qt.Key_Escape);
        tryCompare(controller, "openPanel", "", 500);
    }

    function test_persistent_keyboard_panel_uses_and_releases_focus_grab() {
        const popup = findChild(hostWindow, "keyboard-popup");
        const focusGrab = findChild(popup, "popup-keyboard-focus-grab");
        const controller = findChild(hostWindow, "bar-surface-controller");
        verify(popup);
        verify(focusGrab);
        verify(controller);
        compare(popup.persistentKeyboardFocus, true);
        tryCompare(focusGrab, "active", true);

        focusGrab.cleared();
        tryCompare(controller, "openPanel", "", 500);
        compare(controller.keyboardPanel, "");
        tryCompare(focusGrab, "active", false);
    }
}
