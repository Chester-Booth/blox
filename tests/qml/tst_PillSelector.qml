import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/shared" as Shared

TestCase {
    id: testCase
    name: "PillSelector"
    when: windowShown

    property var testWindow: null

    Component {
        id: selectorWindow

        Window {
            width: 300
            height: 150
            visible: true
            property int selectionCount: 0
            property string selectedId: ""
            property bool updateSelection: true
            property alias pillSelector: selector

            Rectangle {
                objectName: "before-selector"
                x: 10
                y: 10
                width: 20
                height: 20
                activeFocusOnTab: true
            }

            Shared.PillSelector {
                id: selector
                objectName: "pill-selector"
                x: 20
                y: 40
                width: 260
                title: "Mode"
                currentId: "off"
                options: [
                    {id: "off", label: "Off", icon: "○"},
                    {id: "auto", label: "Automatic", icon: "◐"},
                    {id: "on", label: "On", icon: "●"},
                    {id: "disabled", label: "Unavailable", enabled: false, icon: "×"}
                ]
                onSelected: id => {
                    testCase.testWindow.selectionCount++;
                    testCase.testWindow.selectedId = id;
                    if (testCase.testWindow.updateSelection)
                        currentId = id;
                }
            }
        }
    }

    function cleanup() {
        if (testWindow) {
            testWindow.close();
            testWindow.destroy();
            testWindow = null;
        }
    }

    function init() {
        testWindow = selectorWindow.createObject(testCase);
        verify(testWindow);
        testWindow.requestActivate();
        tryCompare(testWindow, "active", true);
    }

    function option(index) {
        return lookup(testWindow.contentItem, "pill-option-" + index);
    }

    function lookup(item, name) {
        if (item.objectName === name)
            return item;
        const children = item.children || [];
        for (let i = 0; i < children.length; i++) {
            const found = lookup(children[i], name);
            if (found)
                return found;
        }
        return null;
    }

    function tabIntoSelector() {
        const before = lookup(testWindow.contentItem, "before-selector");
        verify(before);
        before.forceActiveFocus();
        tryCompare(before, "activeFocus", true);
        keyClick(Qt.Key_Tab);
        tryCompare(option(0), "activeFocus", true);
    }

    function test_tab_focus_keyboard_activation_and_pointer_share_one_selection_path() {
        tabIntoSelector();
        compare(option(0).Accessible.name, "Off");

        keyClick(Qt.Key_Right);
        tryCompare(option(1), "activeFocus", true);
        keyClick(Qt.Key_Space);
        compare(testWindow.selectionCount, 1);
        compare(testWindow.selectedId, "auto");
        compare(testWindow.pillSelector.visualId, "auto");

        keyClick(Qt.Key_Return);
        compare(testWindow.selectionCount, 1);

        mouseClick(option(2), option(2).width / 2, option(2).height / 2);
        compare(testWindow.selectionCount, 2);
        compare(testWindow.selectedId, "on");
        compare(testWindow.pillSelector.visualId, "on");
    }

    function test_disabled_option_is_skipped_and_cannot_be_clicked() {
        tabIntoSelector();
        keyClick(Qt.Key_End);
        tryCompare(option(2), "activeFocus", true);
        keyClick(Qt.Key_Right);
        tryCompare(option(0), "activeFocus", true);

        mouseClick(option(3), option(3).width / 2, option(3).height / 2);
        compare(testWindow.selectionCount, 0);
        compare(testWindow.pillSelector.currentId, "off");
    }

    function test_pending_selection_rejects_second_keyboard_and_pointer_actions() {
        const selector = lookup(testWindow.contentItem, "pill-selector");
        selector.optimistic = true;
        selector.rollbackDelay = 40;
        testWindow.updateSelection = false;
        tabIntoSelector();
        keyClick(Qt.Key_Right);
        tryCompare(option(1), "activeFocus", true);
        keyClick(Qt.Key_Space);
        compare(testWindow.selectionCount, 1);
        verify(selector.selectionPending);
        compare(selector.visualId, "auto");

        keyClick(Qt.Key_Return);
        mouseClick(option(2), option(2).width / 2, option(2).height / 2);
        compare(testWindow.selectionCount, 1);
        compare(testWindow.selectedId, "auto");

        tryCompare(selector, "selectionPending", false, 500);
        compare(selector.visualId, "off");
        mouseClick(option(2), option(2).width / 2, option(2).height / 2);
        compare(testWindow.selectionCount, 2);
        compare(testWindow.selectedId, "on");
    }
}
