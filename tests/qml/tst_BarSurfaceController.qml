import QtTest
import QtQml
import Quickshell
import Quickshell.Hyprland
import qs.shared
import "../../shell/services" as Services
import "../../shell/shared/WidgetWorkArea.js" as WorkArea

TestCase {
    name: "BarSurfaceController"
    property var originalActiveScreen: null
    property var originalScreens: []
    property string originalBarPosition: ""
    property bool originalThemeReady: true
    property var query: null
    SignalSpy { id: queryStarts; target: query; signalName: "started" }

    Services.BarSurfaceController {
        id: controller
    }

    QtObject { id: keyboardAnchor }
    QtObject { id: firstScreen; property string name: "DP-1"; property int width: 1200; property int height: 900 }
    QtObject { id: secondScreen; property string name: "HDMI-A-1"; property int width: 1600; property int height: 1000 }
    QtObject { id: firstScreenAnchor }
    QtObject { id: secondScreenAnchor }

    function init() {
        originalActiveScreen = controller.activeScreen;
        originalScreens = Quickshell.screens;
        originalBarPosition = Theme.barPosition;
        originalThemeReady = Theme.ready;
        query = findChild(controller, "bar-workarea-observation");
        verify(query);
        queryStarts.clear();
    }

    function comparePanelCentre(expected) {
        compare(controller.horizontalBar ? controller.openPanelX : controller.openPanelY, expected);
    }

    function cleanup() {
        Quickshell.screens = originalScreens;
        Theme.barPosition = originalBarPosition;
        Theme.ready = originalThemeReady;
        if (query.running) query.finish(1, 0);
        controller.externalReservationsByOutput = ({});
        controller.barOpen = true;
        controller.edgeTriggerHovered = false;
        controller.closePanel();
        controller.unregisterPanelAnchor("calendar", keyboardAnchor);
        controller.unregisterPanelAnchor("calendar", firstScreenAnchor);
        controller.unregisterPanelAnchor("calendar", secondScreenAnchor);
        controller.unregisterPanelAnchor("power", keyboardAnchor);
        controller.activeScreen = originalActiveScreen;
        originalActiveScreen = null;
    }

    function prepareReservations() {
        Theme.barPosition = "left";
        Theme.ready = true;
        controller.barOpen = true;
        controller.edgeTriggerHovered = false;
        tryCompare(controller, "barSlide", 1, 500);
        Quickshell.screens = [firstScreen, secondScreen];
        verify(!query.running, "Wait for configured bar frames before observing totals");
    }

    function submitFrames() {
        for (const output of controller.reservationOutputs)
            controller.barFrameSubmitted(output, controller.reservationKey);
    }

    function finishQuery(monitors) {
        verify(query.running);
        query.stdout.text = JSON.stringify(monitors);
        query.stdout.streamFinished();
        query.finish(0, 0);
    }

    function initialMonitors() {
        return [{name: firstScreen.name, reserved: [58, 9, 6, 10]},
            {name: secondScreen.name, reserved: [46, 3, 0, 8]}];
    }

    function test_observation_waits_for_theme_and_each_first_frame_without_startup_delay() {
        prepareReservations();
        Theme.ready = false;
        submitFrames();
        wait(20);
        verify(!query.running);
        compare(Object.keys(controller.externalReservationsByOutput).length, 0);
        Theme.ready = true;
        controller.barFrameSubmitted(firstScreen.name, controller.reservationKey);
        wait(20);
        verify(!query.running);
        controller.barFrameSubmitted(secondScreen.name, controller.reservationKey);
        tryCompare(query, "running", true, 100);
        compare(controller.reservationObservation.extent, controller.barDepth);
        finishQuery(initialMonitors());
        compare(controller.externalReservationsByOutput[firstScreen.name], [24, 9, 6, 10]);
        compare(controller.externalReservationsByOutput[secondScreen.name], [12, 3, 0, 8]);
        wait(120);
        compare(queryStarts.count, 1, "No idle observations after a successful read");
    }

    function test_external_same_edge_survives_hide_and_zero_exclusive_hover() {
        prepareReservations();
        submitFrames();
        tryCompare(query, "running", true, 100);
        finishQuery(initialMonitors());
        controller.barOpen = false;
        wait(35);
        verify(controller.occupiedBar.extent > 0 && controller.occupiedBar.extent < 34);
        const external = controller.externalReservationsByOutput[firstScreen.name];
        compare(WorkArea.bounds(1200, 900, external, controller.occupiedBar).x, 24 + controller.occupiedBar.extent);
        tryCompare(controller, "barSlide", 0, 500);
        compare(WorkArea.bounds(1200, 900, external, controller.occupiedBar).x, 24);
        compare(controller.requestedExclusiveZone, 0);
        controller.enterEdgeTrigger();
        tryCompare(controller, "barSlide", 1, 500);
        compare(controller.requestedExclusiveZone, 0);
        compare(WorkArea.bounds(1200, 900, external, controller.occupiedBar).x, 58);
        submitFrames();
        tryCompare(query, "running", true, 100);
        compare(controller.reservationObservation.extent, 0);
        finishQuery([{name: firstScreen.name, reserved: [24, 9, 6, 10]},
            {name: secondScreen.name, reserved: [12, 3, 0, 8]}]);
        compare(controller.externalReservationsByOutput[firstScreen.name], external);
    }

    function test_rotation_removes_old_contribution_once_before_compositor_totals_update() {
        prepareReservations();
        submitFrames();
        tryCompare(query, "running", true, 100);
        finishQuery(initialMonitors());
        Theme.barPosition = "top";
        const external = controller.externalReservationsByOutput[firstScreen.name];
        compare(WorkArea.bounds(1200, 900, external, controller.occupiedBar), Qt.rect(24, 43, 1170, 847));
        verify(!query.running);
        submitFrames();
        tryCompare(query, "running", true, 100);
        compare(controller.reservationObservation.position, "top");
        finishQuery([{name: firstScreen.name, reserved: [24, 43, 6, 10]},
            {name: secondScreen.name, reserved: [12, 37, 0, 8]}]);
        compare(controller.externalReservationsByOutput[firstScreen.name], external);
        controller.barOpen = false;
        tryCompare(controller, "barSlide", 0, 500);
        compare(WorkArea.bounds(1200, 900, external, controller.occupiedBar), Qt.rect(24, 9, 1170, 881));
    }

    function test_changed_request_discards_inflight_read_even_after_return_to_same_edge() {
        prepareReservations();
        submitFrames();
        tryCompare(query, "running", true, 100);
        verify(!controller.observeReservations(), "Only one observation process may run");
        Theme.barPosition = "top";
        Theme.barPosition = "left";
        finishQuery(initialMonitors());
        compare(Object.keys(controller.externalReservationsByOutput).length, 0);
        wait(80);
        verify(!query.running, "A returned key still needs a frame for its new revision");
        submitFrames();
        tryCompare(query, "running", true, 100);
        finishQuery(initialMonitors());
        compare(controller.externalReservationsByOutput[firstScreen.name][0], 24);
    }

    function test_hotplug_retains_idle_output_confirmation_and_requires_only_new_frame() {
        prepareReservations();
        Quickshell.screens = [firstScreen];
        submitFrames();
        tryCompare(query, "running", true, 100);
        finishQuery(initialMonitors());
        const idleKey = controller.presentedReservations[firstScreen.name];
        Quickshell.screens = [firstScreen, secondScreen];
        compare(controller.presentedReservations[firstScreen.name], idleKey);
        verify(!controller.externalReservationsByOutput[secondScreen.name]);
        wait(20);
        verify(!query.running);
        // The original output stays idle. Only the new bar submits a frame.
        controller.barFrameSubmitted(secondScreen.name, controller.reservationKey);
        tryCompare(query, "running", true, 100);
        finishQuery(initialMonitors());
        compare(controller.externalReservationsByOutput[secondScreen.name][0], 12);
        Quickshell.screens = [firstScreen];
        tryCompare(query, "running", true, 100);
        verify(!controller.externalReservationsByOutput[secondScreen.name]);
        finishQuery(initialMonitors());
        // A reconnected name must not reuse its removed frame or reservations.
        Quickshell.screens = [firstScreen, secondScreen];
        verify(controller.presentedReservations[secondScreen.name] === undefined);
        verify(!controller.externalReservationsByOutput[secondScreen.name]);
        wait(20);
        verify(!query.running);
    }

    function test_failures_retry_boundedly_and_only_relevant_events_rearm() {
        prepareReservations();
        submitFrames();
        for (let attempt = 0; attempt < 3; attempt++) {
            tryCompare(query, "running", true, 200);
            query.finish(1, 0);
        }
        wait(120);
        compare(queryStarts.count, 3);
        verify(!query.running);
        Hyprland.rawEvent({name: "workspace"});
        wait(80);
        compare(queryStarts.count, 3);
        Hyprland.rawEvent({name: "openlayer"});
        tryCompare(query, "running", true, 100);
        finishQuery(initialMonitors());
        wait(120);
        compare(queryStarts.count, 4);
    }

    function test_hung_observation_is_terminated_before_any_retry() {
        prepareReservations();
        submitFrames();
        tryCompare(query, "running", true, 100);
        query.sentSignals = [];
        tryVerify(() => query.sentSignals.indexOf(15) >= 0, 1800);
        tryVerify(() => query.sentSignals.indexOf(9) >= 0, 500);
        compare(queryStarts.count, 1);
        finishQuery(initialMonitors());
        compare(Object.keys(controller.externalReservationsByOutput).length, 0);
    }

    function test_widget_bar_extent_follows_hide_and_hover_reveal() {
        controller.barOpen = true;
        tryCompare(controller, "barSlide", 1, 500);
        compare(controller.occupiedBar.position, Theme.barPosition);
        compare(controller.occupiedBar.extent, controller.barDepth);
        controller.barOpen = false;
        tryCompare(controller, "barSlide", 0, 500);
        compare(controller.occupiedBar.extent, 0);
        controller.enterEdgeTrigger();
        tryCompare(controller, "barSlide", 1, 500);
        compare(controller.occupiedBar.extent, controller.barDepth);
    }

    function test_keyboard_open_validates_sections_and_close_clears_focus_state() {
        verify(!controller.openKeyboardPanel("unknown"));
        compare(controller.openPanel, "");
        compare(controller.keyboardPanel, "");

        verify(controller.openKeyboardPanel("calendar"));
        compare(controller.openPanel, "calendar");
        compare(controller.keyboardPanel, "calendar");
        compare(controller.panelState(), {
            "openPanel": "calendar",
            "keyboardPanel": "calendar",
            "keyboardOpen": true
        });

        controller.closePanel();
        compare(controller.openPanel, "");
        compare(controller.keyboardPanel, "");
        compare(controller.panelState().keyboardOpen, false);
    }

    function test_hover_open_does_not_take_keyboard_focus_and_closes_after_pointer_leaves() {
        controller.hoverButtonEntered("notifications", 8, "notifications");
        compare(controller.openPanel, "notifications");
        compare(controller.keyboardPanel, "");

        controller.hoverButtonExited("notifications");
        tryCompare(controller, "openPanel", "", 500);
    }

    function test_explicit_keyboard_open_blocks_hover_close_until_closed() {
        verify(controller.openKeyboardPanel("todo"));
        controller.scheduleHoverClose();
        wait(260);
        compare(controller.openPanel, "todo");
        compare(controller.keyboardPanel, "todo");

        controller.closePanel();
        verify(controller.openKeyboardPanel("updates"));
        controller.openHoverPanel("privacy");
        compare(controller.keyboardPanel, "");
        compare(controller.openPanel, "privacy");
    }

    function test_keyboard_open_uses_registered_anchor_before_any_hover() {
        controller.registerPanelAnchor("calendar", keyboardAnchor, 137, 1);

        verify(controller.openKeyboardPanel("calendar"));
        comparePanelCentre(137);
    }

    function test_open_hover_panel_without_coordinate_uses_registered_anchor() {
        controller.registerPanelAnchor("power", keyboardAnchor, 243, 1);

        controller.openHoverPanel("power");
        comparePanelCentre(243);
    }

    function test_keyboard_open_tracks_registered_item_geometry_changes() {
        controller.registerPanelAnchor("calendar", keyboardAnchor, 96, 1);
        verify(controller.openKeyboardPanel("calendar"));

        controller.registerPanelAnchor("calendar", keyboardAnchor, 184, 1);
        comparePanelCentre(184);
    }

    function test_keyboard_open_uses_and_tracks_the_active_screen_anchor() {
        Quickshell.screens = [firstScreen, secondScreen];
        controller.activeScreen = firstScreen;
        controller.registerPanelAnchor("calendar", firstScreenAnchor, 121, 1, firstScreen);
        controller.registerPanelAnchor("calendar", secondScreenAnchor, 433, 1, secondScreen);

        verify(controller.openKeyboardPanel("calendar"));
        comparePanelCentre(121);

        controller.activeScreen = secondScreen;
        comparePanelCentre(433);
    }

    function test_tray_menu_holds_expanded_tray_until_menu_closes() {
        const item = {
            menu: ({}),
            hasMenu: true,
            onlyMenu: false,
            title: "Tray item",
            id: "tray-item",
            activate: function() {}
        };

        controller.openTrayMenu(item, 40);
        verify(controller.trayOpen);
        verify(controller.trayMenuOpen);
        controller.trayExited();
        wait(260);
        verify(controller.trayOpen);
        verify(controller.trayMenuOpen);

        controller.closeTrayMenu();
        tryCompare(controller, "trayOpen", false, 500);
        verify(!controller.trayMenuOpen);
    }

    function test_open_hover_panel_before_any_hover_syncs_screen_and_avoids_top_left() {
        Quickshell.screens = [firstScreen];
        controller.activeScreen = null;
        controller.registerPanelAnchor("notifications", firstScreenAnchor, 742, 1, firstScreen);

        controller.openHoverPanel("notifications");
        compare(controller.activeScreen, firstScreen);
        comparePanelCentre(742);
    }

    function test_fallback_centre_uses_first_screen_when_active_screen_is_unset() {
        Quickshell.screens = [firstScreen];
        controller.activeScreen = null;

        controller.openHoverPanel("updates");
        compare(controller.activeScreen, firstScreen);
        comparePanelCentre(controller.horizontalBar ? firstScreen.width / 2 : firstScreen.height / 2);
    }
}
