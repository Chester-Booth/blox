import QtQuick
import QtQuick.Window
import QtTest
import qs.popouts as NativePopouts

TestCase {
    id: testCase
    name: "CalendarHeaderAccessibility"
    when: windowShown
    property var testWindow: null

    Component {
        id: calendarWindowComponent
        Window {
            visible: true
            width: 400
            height: 400

            QtObject {
                id: fakeCalendar
                property date selectedDate: new Date(2026, 9, 9)
                property var events: []
                property var calendars: []
                property bool refreshing: false
                property var popoutNotice: null
                property bool childWindowOpen: false
                property bool editorOpen: false
                function snapshot() {}
                function finishNavigation() {}
                function refreshViewedDate() {}
                function createEvent() {}
                function retryNotice() {}
            }

            NativePopouts.CalendarPopout {
                objectName: "calendar-popout"
                x: 20
                y: 20
                controller: fakeCalendar
            }
        }
    }

    function lookup(item, name) {
        if (item.objectName === name)
            return item;
        for (const child of item.children || []) {
            const found = lookup(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function init() {
        testWindow = calendarWindowComponent.createObject(testCase);
        verify(testWindow);
        tryCompare(testWindow, "visible", true);
        wait(20);
    }

    function cleanup() {
        if (testWindow) {
            testWindow.close();
            testWindow.destroy();
            testWindow = null;
        }
    }

    function test_first_tab_reaches_named_calendar_header_control() {
        const calendar = lookup(testWindow.contentItem, "calendar-popout");
        const previous = lookup(testWindow.contentItem, "calendar-prev");
        const view = lookup(testWindow.contentItem, "calendar-view");
        const create = lookup(testWindow.contentItem, "calendar-create");
        const next = lookup(testWindow.contentItem, "calendar-next");
        verify(calendar);
        verify(previous);
        verify(view);
        verify(create);
        verify(next);

        calendar.forceActiveFocus();
        tryCompare(calendar, "activeFocus", true);
        keyClick(Qt.Key_Tab);
        tryCompare(testWindow, "activeFocusItem", previous);
        compare(previous.Accessible.role, Accessible.Button);
        compare(previous.Accessible.name, "Previous month");
        compare(view.Accessible.name, "Show day");
        compare(create.Accessible.name, "Create event");
        compare(next.Accessible.name, "Next month");

        calendar.viewIndex = 1;
        wait(20);
        compare(previous.Accessible.name, "Previous day");
        compare(view.Accessible.name, "Show calendar");
        compare(next.Accessible.name, "Next day");
    }
}
