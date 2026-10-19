import QtQuick
import QtTest
import qs.popouts as NativePopouts
import qs.shared

TestCase {
    id: testCase
    name: "CalendarMonthSizing"
    when: windowShown
    width: 400
    height: 800

    QtObject {
        id: controller
        property date selectedDate: new Date(2026, 9, 17)
        property var events: []
        property var calendars: []
        property bool refreshing: false
        property var popoutNotice: null
        property bool childWindowOpen: false
        property bool editorOpen: false
    }

    NativePopouts.CalendarPopout {
        id: popup
        controller: controller
    }

    function findLabel(item, text) {
        if (item.text === text)
            return item;
        for (const child of item.children || []) {
            const found = findLabel(child, text);
            if (found)
                return found;
        }
        return null;
    }

    function test_wrapped_calendars_fit_and_popup_shrinks_again() {
        const compactHeight = popup.height;
        const calendars = [];
        const events = [];
        for (let i = 0; i < 8; ++i) {
            calendars.push({id: String(i), summary: "Calendar with a long name " + i, colour: "#ffffff"});
            events.push({calendar: {id: String(i)}, title: "Event", colour: {display: "#ffffff", calendar_fallback: "#ffffff"},
                time: {kind: "all_day", start_date: "2026-10-01", end_date_exclusive: "2026-11-01"}});
        }
        controller.calendars = calendars;
        controller.events = events;
        tryVerify(() => popup.height > compactHeight);
        const label = findLabel(popup, calendars[7].summary);
        verify(label);
        verify(label.mapToItem(popup, 0, label.height).y <= popup.height - Theme.scaledSpacing(12));

        popup.viewIndex = 1;
        compare(popup.height, popup.dayViewHeight);
        popup.viewIndex = 0;
        controller.events = [];
        controller.calendars = [];
        tryCompare(popup, "height", compactHeight);
    }
}
