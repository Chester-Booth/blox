import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/modules" as Modules

TestCase {
    id: testCase
    name: "CalendarEventDescriptionScroll"
    when: windowShown

    property var testWindow: null
    readonly property string longDescription: Array.from({length: 60}, (_, index) =>
        "Calendar description scroll fixture line " + (index + 1)).join("\n")

    Component {
        id: editorWindow

        Window {
            width: 420
            height: 220
            visible: true

            Modules.CalendarEventDescriptionField {
                objectName: "calendar-event-description-field"
                x: 20
                y: 20
                width: 360
                height: 170
                text: testCase.longDescription
            }
        }
    }

    function init() {
        testWindow = editorWindow.createObject(testCase);
        verify(testWindow);
        tryCompare(testWindow, "visible", true);
    }

    function cleanup() {
        if (!testWindow)
            return;
        testWindow.close();
        testWindow.destroy();
        testWindow = null;
    }

    function wheel(item, delta) {
        const point = item.mapToItem(testWindow.contentItem,
            Math.floor(item.width / 2), Math.floor(item.height / 2));
        mouseMove(testWindow.contentItem, point.x, point.y);
        mouseWheel(testWindow.contentItem, point.x, point.y,
            0, delta, Qt.NoButton, Qt.NoModifier);
    }

    function test_long_description_scrolls_with_wheel_and_cursor() {
        const scroll = findChild(testWindow, "calendar-event-description-scroll");
        const description = findChild(testWindow, "calendar-event-description");
        verify(scroll);
        verify(description);

        const scrollbar = findChild(testWindow, "calendar-event-description-scrollbar");
        verify(scrollbar);
        compare(scrollbar.parent, scroll);
        compare(scrollbar.y, 0);
        compare(scrollbar.height, scroll.height);
        compare(scrollbar.x + scrollbar.width, scroll.width);

        const flickable = scroll.contentItem;
        verify(flickable && typeof flickable.contentY === "number"
                && typeof flickable.contentHeight === "number"
                && typeof flickable.height === "number",
            "ScrollView should provide its interactive Flickable viewport");
        verify(flickable.contentHeight > flickable.height + 1,
            "The fixture description should overflow the viewport");
        compare(flickable.contentY, flickable.originY);

        wheel(flickable, -120);
        tryVerify(() => flickable.contentY > flickable.originY);
        verify(flickable.contentY <= flickable.originY
                + flickable.contentHeight - flickable.height + 1,
            "Wheel scrolling should stay within the description bounds");
        wheel(flickable, 120);
        tryCompare(flickable, "contentY", flickable.originY);

        testWindow.requestActivate();
        tryCompare(testWindow, "active", true, 3000);
        description.forceActiveFocus();
        tryCompare(description, "activeFocus", true);
        description.cursorPosition = 0;
        keyClick(Qt.Key_End, Qt.ControlModifier);
        compare(description.cursorPosition, description.length);
        tryVerify(() => flickable.contentY > flickable.originY);
    }
}
