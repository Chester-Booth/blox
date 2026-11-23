import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/popouts" as Popouts
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "CalendarPopupFocusLifecycle"
    when: windowShown
    property var testWindow: null

    Component {
        id: ownerWindow

        Window {
            id: host

            width: 640
            height: 700
            visible: true

            Services.BarSurfaceController {
                id: surfaceController
                objectName: "bar-surface-controller"
            }

            Popouts.BarPopoutGeometry {
                id: geometry

                panelWindow: host
                active: true
                screenWidth: host.width
                screenHeight: host.height
            }

            Services.BarContentController {
                id: contentController
                objectName: "bar-content-controller"
                scriptRoot: "/nonexistent"
            }

            Popouts.BarCalendarSurface {
                objectName: "bar-calendar-surface"
                geometry: geometry
                surfaceController: surfaceController
                contentController: contentController
            }
        }
    }

    function init() {
        testWindow = ownerWindow.createObject(testCase);
        verify(testWindow);
        tryCompare(testWindow, "visible", true);
        const surfaceController = findChild(testWindow, "bar-surface-controller");
        verify(surfaceController.openKeyboardPanel("calendar"));
        tryCompare(findChild(testWindow, "popup-keyboard-focus-grab"), "active", true);
    }

    function cleanup() {
        if (testWindow) {
            testWindow.close();
            testWindow.destroy();
            testWindow = null;
        }
    }

    function popupWindow() {
        const popup = findChild(testWindow, "calendar-popup-window");
        verify(popup);
        return popup;
    }

    function test_outside_clear_dismisses_inline_menu_and_calendar_owner() {
        const surfaceController = findChild(testWindow, "bar-surface-controller");
        const calendarController = findChild(testWindow, "bar-content-controller").calendarController;
        const popup = popupWindow();
        const focusGrab = findChild(testWindow, "popup-keyboard-focus-grab");
        const eventMenu = findChild(testWindow, "calendar-event-menu");
        verify(eventMenu);

        eventMenu.event = {can_edit: true, busy: false, capability_reason: "", colour: {event_id: "1"}};
        eventMenu.open();
        tryCompare(eventMenu, "opened", true);
        tryCompare(calendarController, "eventMenuOpen", true);
        popup.requestKeyboardFocus();
        tryCompare(surfaceController, "inputPopupLocked", true);
        verify(popup.dismissOnFocusClear);

        focusGrab.cleared();

        tryCompare(eventMenu, "opened", false);
        compare(calendarController.eventMenuOpen, false);
        compare(surfaceController.inputPopupLocked, false);
        compare(surfaceController.openPanel, "");
        compare(surfaceController.keyboardPanel, "");
        compare(popup.keyboardFocus, false);
    }

    function test_external_child_releases_focus_without_dismissing_owner() {
        const surfaceController = findChild(testWindow, "bar-surface-controller");
        const calendarController = findChild(testWindow, "bar-content-controller").calendarController;
        const calendarSurface = findChild(testWindow, "bar-calendar-surface");
        const popup = popupWindow();
        const focusGrab = findChild(testWindow, "popup-keyboard-focus-grab");

        calendarController.eventMenuOpen = true;
        popup.requestKeyboardFocus();
        calendarController.eventMenuOpen = false;
        compare(surfaceController.inputPopupLocked, false);
        calendarController.editorOpen = true;

        compare(calendarSurface.externalChildWindowOpen, true);
        compare(calendarController.childWindowOpen, true);
        compare(surfaceController.openPanel, "calendar");
        compare(surfaceController.keyboardPanel, "calendar");
        compare(surfaceController.inputPopupLocked, true);
        compare(popup.keyboardFocus, false);
        verify(!popup.dismissOnFocusClear);
        tryCompare(focusGrab, "active", false);

        focusGrab.cleared();

        compare(surfaceController.openPanel, "calendar");
        compare(surfaceController.keyboardPanel, "calendar");
        compare(surfaceController.inputPopupLocked, true);
        compare(calendarController.editorOpen, true);

        calendarController.editorOpen = false;
        compare(surfaceController.inputPopupLocked, false);
        compare(surfaceController.openPanel, "calendar");
        compare(surfaceController.keyboardPanel, "calendar");
        verify(popup.persistentKeyboardFocus);
    }
}
