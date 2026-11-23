import QtQuick
import QtTest
import Quickshell
import qs.shared
import "../../shell/popouts" as Popouts

TestCase {
    id: testCase
    name: "TraySubmenus"
    when: windowShown
    visible: true
    width: 1100
    height: 720

    QtObject {
        id: leaf
        property bool enabled: true
        property bool isSeparator: false
        property bool hasChildren: false
        property string text: "Older chat"
        property string icon: Qt.resolvedUrl("../../shell/assets/phosphor/plus.svg")
        property int buttonType: QsMenuButtonType.None
        property int checkState: Qt.Unchecked
        property int activations: 0
        function triggered() { activations++; }
    }
    QtObject {
        id: disabledEntry
        property bool enabled: false
        property bool isSeparator: false
        property string text: "Disabled"
    }
    QtObject {
        id: separator
        property bool enabled: true
        property bool isSeparator: true
        property string text: ""
    }
    QtObject {
        id: nested
        property bool enabled: true
        property bool isSeparator: false
        property bool hasChildren: true
        property string text: "Nested"
        property var items: [leaf]
        property int activations: 0
        function triggered() { activations++; }
    }
    QtObject {
        id: more
        property bool enabled: true
        property bool isSeparator: false
        property bool hasChildren: true
        property string text: "More"
        property var items: [leaf, nested]
        property int activations: 0
        function triggered() { activations++; }
    }
    QtObject { id: menu; property var items: [more, disabledEntry, separator, leaf] }
    Popouts.TrayMenuPopout {
        id: popup
        menuHandle: menu
        keyboardOpen: true
        screenWidth: 1100
        screenHeight: 720
    }
    SignalSpy { id: actionSpy; target: popup; signalName: "triggered" }
    SignalSpy { id: closeSpy; target: popup; signalName: "closeRequested" }

    function panel(depth) { return depth === 0 ? popup.rootPanel : popup.submenuStack[depth - 1]; }
    function entry(index, depth) { return panel(depth || 0).rowAt(index); }
    function init() {
        mouseMove(testCase, width - 1, height - 1);
        popup.resetNavigation();
        popup.menuHandle = menu;
        popup.keyboardOpen = false;
        popup.keyboardOpen = true;
        popup.screenHeight = 720;
        popup.screenWidth = 1100;
        popup.rootScreenX = 42;
        popup.rootScreenY = 8;
        Theme.barPosition = "left";
        leaf.activations = 0;
        leaf.text = "Older chat";
        leaf.buttonType = QsMenuButtonType.None;
        leaf.checkState = Qt.Unchecked;
        more.enabled = true;
        more.items = [leaf, nested];
        actionSpy.clear();
        closeSpy.clear();
        wait(20);
    }

    function test_mouse_submenu_and_action() {
        mouseClick(entry(0), 40, 14);
        compare(popup.submenuStack.length, 1);
        compare(more.activations, 0);
        compare(actionSpy.count, 0);
        verify(panel(1).x >= popup.rootPanel.x + popup.rootPanel.width);
        compare(popup.rootPanel.menuHandle, menu);
        entry(0).forceActiveFocus();
        entry(0).activate();
        compare(panel(1).selectedIndex, -1);
        mouseClick(entry(0, 1), 40, 14);
        compare(leaf.activations, 1);
        compare(actionSpy.count, 1);
    }

    function test_nested_keyboard_and_skip_disabled() {
        entry(0).forceActiveFocus();
        keyClick(Qt.Key_Down);
        tryVerify(() => entry(3).activeFocus);
        keyClick(Qt.Key_Down);
        tryVerify(() => entry(0).activeFocus);
        keyClick(Qt.Key_Up);
        tryVerify(() => entry(3).activeFocus);
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Right);
        compare(popup.submenuStack.length, 1);
        compare(panel(1).selectedIndex, -1);
        keyClick(Qt.Key_Up);
        tryVerify(() => entry(1, 1).activeFocus);
        keyClick(Qt.Key_Return);
        compare(popup.submenuStack.length, 2);
        compare(nested.activations, 0);
        compare(panel(2).selectedIndex, -1);
        keyClick(Qt.Key_Down);
        tryVerify(() => entry(0, 2).activeFocus);
        keyClick(Qt.Key_Left);
        compare(popup.submenuStack.length, 1);
        tryVerify(() => entry(1, 1).activeFocus);
        keyClick(Qt.Key_Escape);
        compare(popup.submenuStack.length, 0);
        tryVerify(() => entry(0).activeFocus);
        compare(closeSpy.count, 0);
        keyClick(Qt.Key_Escape);
        compare(closeSpy.count, 1);
    }

    function test_hover_opens_submenu_and_sibling_closes_it() {
        mouseMove(entry(0), 40, 14);
        tryVerify(() => popup.submenuStack.length === 1);
        mouseMove(entry(3), 40, 14);
        tryVerify(() => popup.submenuStack.length === 0);
        compare(more.activations, 0);
    }

    function test_scrollbar_does_not_overlap_rows() {
        more.items = Array.from({length: 30}, () => leaf);
        popup.screenHeight = 260;
        popup.openSubmenu(popup.rootPanel, more, 0);
        const child = panel(1);
        const scroll = child.scroll;
        const bar = findChild(child, "tray-menu-scrollbar");
        tryCompare(bar, "visible", true);
        const barLeft = bar.mapToItem(child, 0, 0).x;
        verify(entry(0, 1).mapToItem(child, entry(0, 1).width, 0).x < barLeft);
        scroll.contentY = scroll.contentHeight - scroll.height;
        child.focusRow(29);
        verify(scroll.contentY > 0);
    }

    function test_check_radio_and_icon_states() {
        const row = entry(3);
        const indicator = findChild(row, "tray-menu-indicator-3");
        const icon = findChild(row, "tray-menu-icon-3");
        verify(icon.visible);
        leaf.buttonType = QsMenuButtonType.CheckBox;
        leaf.checkState = Qt.Checked;
        verify(indicator.visible);
        compare(indicator.iconName, "check-square");
        leaf.checkState = Qt.PartiallyChecked;
        compare(indicator.iconName, "minus-square");
        leaf.checkState = Qt.Unchecked;
        compare(indicator.iconName, "square");
        leaf.buttonType = QsMenuButtonType.RadioButton;
        leaf.checkState = Qt.Checked;
        compare(indicator.iconName, "radio-button");
        leaf.checkState = Qt.Unchecked;
        compare(indicator.iconName, "circle");
        row.activate();
        compare(leaf.activations, 1);
        compare(leaf.checkState, Qt.Unchecked); // The application owns the state.
    }

    function test_toggle_keeps_menu_open_data() {
        return [
            {tag: "checkbox", type: QsMenuButtonType.CheckBox},
            {tag: "radio", type: QsMenuButtonType.RadioButton}
        ];
    }
    function test_toggle_keeps_menu_open(data) {
        leaf.buttonType = data.type;
        mouseClick(entry(3), 40, 14);
        compare(leaf.activations, 1);
        compare(actionSpy.count, 0);
        compare(closeSpy.count, 0);
        popup.openSubmenu(popup.rootPanel, more, 0);
        panel(1).focusRow(0);
        keyClick(Qt.Key_Space);
        compare(leaf.activations, 2);
        compare(popup.submenuStack.length, 1);
        compare(actionSpy.count, 0);
        compare(closeSpy.count, 0);
    }

    function test_truncated_label_tooltip() {
        const row = entry(3);
        const label = findChild(row, "tray-menu-label-3");
        const tooltip = findChild(row, "tray-menu-tooltip-3");
        mouseMove(row, 40, 14);
        verify(!label.truncated);
        verify(!tooltip.shown);
        leaf.text = "A conversation title long enough to be truncated in the tray menu";
        tryCompare(label, "truncated", true);
        tryCompare(tooltip, "visible", true);
        compare(tooltip.text, leaf.text);
        keyClick(Qt.Key_Up);
        tryCompare(tooltip, "visible", false);
    }

    function test_placement_data() {
        return [
            {tag:"left", position:"left", x:42, y:600, direction:1},
            {tag:"right", position:"right", x:818, y:600, direction:-1},
            {tag:"top-right", position:"top", x:810, y:42, direction:-1},
            {tag:"bottom-left", position:"bottom", x:8, y:420, direction:1}
        ];
    }
    function test_placement(data) {
        Theme.barPosition = data.position;
        popup.rootScreenX = data.x;
        popup.rootScreenY = data.y;
        more.items = Array.from({length:30}, () => leaf);
        popup.openSubmenu(popup.rootPanel, more, 0);
        wait(20);
        const child = panel(1);
        compare(Math.sign(child.panelX), data.direction);
        verify(data.x + child.panelX >= 8);
        verify(data.x + child.panelX + child.width <= popup.screenWidth - 8);
        verify(data.y + child.panelY >= (data.position === "top" ? Theme.railWidth : 0) + 8);
        verify(data.y + child.panelY + child.height <= popup.screenHeight - (data.position === "bottom" ? Theme.railWidth : 0) - 8);
        // Expanding the popup must not move the original menu on screen.
        compare(popup.rootPanel.x + popup.offsetX, 0);
        compare(popup.rootPanel.y + popup.offsetY, 0);
    }

    function test_late_children_and_handle_reset() {
        more.items = [];
        popup.openSubmenu(popup.rootPanel, more, 0);
        wait(20);
        more.items = [leaf];
        compare(panel(1).selectedIndex, -1);
        keyClick(Qt.Key_Down);
        tryVerify(() => entry(0, 1).activeFocus);
        popup.menuHandle = null;
        compare(popup.submenuStack.length, 0);
    }

    function test_mouse_and_keyboard_share_one_selection() {
        popup.rootPanel.forceActiveFocus();
        compare(popup.rootPanel.selectedIndex, -1);
        keyClick(Qt.Key_Up);
        compare(popup.rootPanel.selectedIndex, 3);
        mouseMove(entry(0), 40, 14);
        compare(popup.rootPanel.selectedIndex, 0);
        keyClick(Qt.Key_Down);
        compare(popup.rootPanel.selectedIndex, 3);
        compare(entry(0).color, Qt.color("transparent"));
        keyClick(Qt.Key_Up);
        compare(popup.rootPanel.selectedIndex, 0);
        keyClick(Qt.Key_Right);
        compare(panel(1).selectedIndex, -1);
        mouseMove(entry(1, 1), 40, 14);
        compare(panel(1).selectedIndex, 1);
        keyClick(Qt.Key_Up);
        compare(panel(1).selectedIndex, 0);
        compare(entry(1, 1).color, Qt.color("transparent"));
    }

    function test_disabled_submenu() {
        more.enabled = false;
        entry(0).activate();
        compare(popup.submenuStack.length, 0);
        compare(more.activations, 0);
        compare(actionSpy.count, 0);
    }
}
