import QtQuick
import QtTest
import Quickshell
import Quickshell.Hyprland
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "PowerStartup"
    property var controller: null
    readonly property bool firstOpen: controller !== null && controller.activeScreen === firstScreen && controller.openPanel === "power"
    readonly property bool secondOpen: controller !== null && controller.activeScreen === secondScreen && controller.openPanel === "power"
    property var savedScreens
    property var savedFocus
    property var savedMonitors

    Component { id: fixture; Services.BarSurfaceController {} }
    QtObject { id: firstScreen; property string name: "DP-1"; property int width: 1200; property int height: 900 }
    QtObject { id: secondScreen; property string name: "HDMI-A-1"; property int width: 1600; property int height: 1000 }
    QtObject { id: thirdScreen; property string name: "DP-3"; property int width: 1800; property int height: 1100 }
    QtObject { id: firstMonitor }
    QtObject { id: secondMonitor }
    QtObject { id: powerAnchor }

    // Bar forwards WorkspaceController's focusedMonitorChanged signal here.
    Connections {
        target: Hyprland
        function onFocusedMonitorChanged() {
            if (controller) controller.syncActiveScreenToFocus();
        }
    }

    function init() {
        savedScreens = Quickshell.screens;
        savedFocus = Hyprland.focusedMonitor;
        savedMonitors = Hyprland.monitorsByName;
        Quickshell.screens = [];
        Hyprland.focusedMonitor = null;
        Hyprland.monitorsByName = ({"DP-1": firstMonitor, "HDMI-A-1": secondMonitor});
    }

    function cleanup() {
        controller = null;
        Quickshell.screens = savedScreens;
        Hyprland.focusedMonitor = savedFocus;
        Hyprland.monitorsByName = savedMonitors;
    }

    function start(screens, focused) {
        Quickshell.screens = screens;
        Hyprland.focusedMonitor = focused;
        controller = createTemporaryObject(fixture, testCase);
        verify(controller !== null);
        const handler = power();
        verify(handler !== null, "Power IPC is eager, without loading or clicking a bar item");
        return handler;
    }

    function power() {
        for (const child of controller.data) {
            if (child.target === "power") return child;
        }
        return null;
    }

    function test_empty_start_without_focus_accepts_late_screen() {
        const ipc = start([], null);
        compare(controller.activeScreen, null);
        compare(ipc.toggle(), "open");
        Quickshell.screens = [firstScreen];
        compare(controller.activeScreen, firstScreen);
        verify(firstOpen);
    }

    function test_focused_screen_ready_before_any_anchor_or_pointer() {
        const ipc = start([firstScreen, secondScreen], secondMonitor);
        compare(controller.activeScreen, secondScreen);
        compare(Object.keys(controller.panelAnchorCandidates).length, 0);
        compare(ipc.toggle(), "open");
        verify(secondOpen);
        compare(controller.openPanelY, secondScreen.height / 2);
    }

    function test_focus_mapping_ready_after_controller_before_first_key() {
        Hyprland.monitorsByName = ({});
        const ipc = start([firstScreen, secondScreen], secondMonitor);
        compare(controller.activeScreen, firstScreen);
        Hyprland.monitorsByName = ({"DP-1": firstMonitor, "HDMI-A-1": secondMonitor});
        compare(ipc.toggle(), "open");
        verify(secondOpen, "The first key must resolve the now-ready focused output");
    }

    function test_key_before_screen_readiness_selects_focused_output_when_it_arrives() {
        const ipc = start([], secondMonitor);
        compare(ipc.open(), "open");
        Quickshell.screens = [firstScreen];
        verify(firstOpen);
        Quickshell.screens = [firstScreen, secondScreen];
        verify(secondOpen, "Screen readiness must retry the already-known monitor focus");
        compare(controller.openPanelY, secondScreen.height / 2);
    }

    function test_power_ipc_is_keyboard_open_and_survives_pointer_exit() {
        const ipc = start([firstScreen], null);
        compare(ipc.open(), "open");
        compare(controller.keyboardPanel, "power");
        controller.scheduleHoverClose();
        wait(260);
        verify(firstOpen);
        compare(controller.keyboardPanel, "power");
    }

    function test_power_survives_a_popout_exit_without_a_prior_click() {
        const ipc = start([firstScreen], null);
        compare(ipc.toggle(), "open");
        controller.popoutExited();
        wait(260);
        verify(firstOpen, "A keyboard-opened power menu must survive pointer exit");
    }

    function test_power_toggle_close_open_and_explicit_close_reset_keyboard_state() {
        const ipc = start([firstScreen], firstMonitor);
        compare(ipc.toggle(), "open");
        verify(firstOpen);
        compare(controller.keyboardPanel, "power");
        compare(ipc.toggle(), "closed");
        compare(controller.openPanel, "");
        compare(controller.keyboardPanel, "");
        compare(ipc.toggle(), "open");
        verify(firstOpen);
        compare(ipc.open(), "open");
        verify(firstOpen);
        compare(ipc.close(), "closed");
        compare(controller.openPanel, "");
        compare(controller.keyboardPanel, "");
    }

    function test_late_anchor_registration_and_removal_without_pointer() {
        const ipc = start([firstScreen], null);
        compare(ipc.open(), "open");
        compare(controller.openPanelY, firstScreen.height / 2);
        controller.registerPanelAnchor("power", powerAnchor, 173, 1, firstScreen);
        compare(controller.openPanelAnchorItem, powerAnchor);
        compare(controller.openPanelY, 173);
        controller.unregisterPanelAnchor("power", powerAnchor);
        compare(controller.openPanelAnchorItem, null);
        compare(controller.openPanelY, firstScreen.height / 2);
        verify(firstOpen);
    }

    function test_late_focus_reanchors_keyboard_power_without_pointer() {
        const ipc = start([firstScreen, secondScreen], null);
        compare(ipc.open(), "open");
        verify(firstOpen);
        controller.registerPanelAnchor("power", powerAnchor, 173, 1, secondScreen);
        Hyprland.focusedMonitor = secondMonitor;
        verify(secondOpen);
        compare(controller.openPanelAnchorItem, powerAnchor);
        compare(controller.openPanelY, 173);
    }

    function test_unplug_selected_output_does_not_leave_power_open_on_no_window() {
        const ipc = start([firstScreen, secondScreen], secondMonitor);
        compare(ipc.open(), "open");
        verify(secondOpen);
        Quickshell.screens = [firstScreen];
        verify(firstOpen, "A removed selected screen must fall back to a live output");
        compare(controller.openPanelY, firstScreen.height / 2);
        Quickshell.screens = [];
        compare(controller.activeScreen, null);
        verify(!firstOpen && !secondOpen);
        Quickshell.screens = [secondScreen, firstScreen];
        verify(secondOpen);
    }

    function test_focused_selection_ignores_output_order_data() {
        return [
            {tag: "first-focus-forward", reverse: false, secondFocus: false},
            {tag: "second-focus-forward", reverse: false, secondFocus: true},
            {tag: "first-focus-reversed", reverse: true, secondFocus: false},
            {tag: "second-focus-reversed", reverse: true, secondFocus: true}
        ];
    }

    function test_focused_selection_ignores_output_order(data) {
        const ipc = start([], null);
        compare(ipc.open(), "open");
        Hyprland.focusedMonitor = data.secondFocus ? secondMonitor : firstMonitor;
        Quickshell.screens = data.reverse ? [secondScreen, firstScreen] : [firstScreen, secondScreen];
        compare(data.secondFocus ? secondOpen : firstOpen, true);
        compare(data.secondFocus ? firstOpen : secondOpen, false);
        compare(controller.openPanelY, data.secondFocus ? secondScreen.height / 2 : firstScreen.height / 2);
    }

    function test_reordered_outputs_keep_initial_keyboard_selection_without_focus() {
        const ipc = start([firstScreen, secondScreen], null);
        compare(ipc.open(), "open");
        verify(firstOpen);
        Quickshell.screens = [secondScreen, firstScreen];
        verify(firstOpen, "Output enumeration order must not move an already-open keyboard menu");
    }

    function test_reordered_outputs_preserve_valid_selection_without_focus() {
        const ipc = start([firstScreen, secondScreen], null);
        controller.activeScreen = secondScreen;
        Quickshell.screens = [secondScreen, firstScreen];
        compare(ipc.open(), "open");
        verify(secondOpen);
        Quickshell.screens = [firstScreen, secondScreen];
        verify(secondOpen);
    }

    function test_close_before_late_screens_does_not_reopen() {
        const ipc = start([], secondMonitor);
        compare(ipc.toggle(), "open");
        compare(ipc.toggle(), "closed");
        Quickshell.screens = [firstScreen, secondScreen];
        verify(!firstOpen && !secondOpen);
        compare(controller.keyboardPanel, "");
    }

    function test_pointer_selection_survives_list_changes_data() {
        return [
            {tag: "hover-reorder", tray: false, reorder: true},
            {tag: "hover-add", tray: false, reorder: false},
            {tag: "tray-reorder", tray: true, reorder: true},
            {tag: "tray-add", tray: true, reorder: false}
        ];
    }

    function test_pointer_selection_survives_list_changes(data) {
        start([firstScreen, secondScreen], firstMonitor);
        controller.activeScreen = secondScreen;
        const menu = {title: "Fixture", menu: ({}), hasMenu: true};
        if (data.tray)
            controller.openTrayMenu(menu, 733);
        else
            controller.hoverButtonEntered("calendar", 733, "calendar", powerAnchor);
        Quickshell.screens = data.reorder ? [secondScreen, firstScreen] : [firstScreen, secondScreen, thirdScreen];
        compare(controller.activeScreen, secondScreen);
        compare(controller.keyboardPanel, "");
        if (data.tray) {
            verify(controller.trayMenuOpen);
            compare(controller.trayMenuHandle, menu.menu);
            compare(controller.trayMenuY, 733);
        } else {
            compare(controller.openPanel, "calendar");
            compare(controller.openPanelAnchorItem, powerAnchor);
            compare(controller.openPanelY, 733);
        }
    }

    function test_pointer_output_removal_closes_its_overlays_data() {
        return [{tag: "hover", tray: false}, {tag: "tray", tray: true}];
    }

    function test_pointer_output_removal_closes_its_overlays(data) {
        start([firstScreen, secondScreen], firstMonitor);
        controller.activeScreen = secondScreen;
        if (data.tray)
            controller.openTrayMenu({title: "Fixture", menu: ({}), hasMenu: true}, 733);
        else
            controller.hoverButtonEntered("calendar", 733, "calendar", powerAnchor);
        Quickshell.screens = [firstScreen];
        compare(controller.activeScreen, firstScreen);
        compare(controller.openPanel, "");
        compare(controller.openPanelAnchorItem, null);
        verify(!controller.trayMenuOpen);
        verify(!controller.trayOpen);
        compare(controller.trayMenuHandle, null);
        Quickshell.screens = [firstScreen, secondScreen];
        compare(controller.openPanel, "");
        verify(!controller.trayOpen);
    }
}
