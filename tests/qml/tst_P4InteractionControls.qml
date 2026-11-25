import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/services" as Services
import "../../shell/popouts" as Popouts
import "../../shell/shared" as Shared

TestCase {
    id: testCase
    name: "P4InteractionControls"
    when: windowShown

    property var testWindow: null
    property var actionsOwner: null

    Component {
        id: actionsComponent
        Services.BarActions { objectName: "test-bar-actions" }
    }

    Component {
        id: controlWindow
        Window {
            id: windowRoot
            width: 640
            height: 480
            visible: true
            property string powerAction: ""
            property int systemClicks: 0
            property int sliderValue: 50
            property var powerOverlayRef: null

            Popouts.PowerOverlay {
                id: powerOverlay
                objectName: "powerOverlay"
                anchors.fill: parent
                overlayOpen: true
                Component.onCompleted: windowRoot.powerOverlayRef = powerOverlay
                onAction: command => windowRoot.powerAction = command
                onClose: overlayOpen = false
            }

            Popouts.SystemSectionButton {
                id: systemSection
                x: 20
                y: 20
                label: "Audio"
                icon: "sound"
                onClicked: windowRoot.systemClicks++
            }

            Popouts.SystemLevelSlider {
                id: systemSlider
                objectName: "system-slider"
                x: 80
                y: 20
                width: 200
                label: "Volume"
                value: windowRoot.sliderValue
                onChanged: next => windowRoot.sliderValue = next
            }
        }
    }

    Component {
        id: tooltipWindow
        Window {
            width: 240
            height: 100
            visible: true
            Rectangle {
                id: keyboardTarget
                objectName: "keyboard-target"
                width: 80
                height: 40
                activeFocusOnTab: true
                Shared.BloxToolTip {
                    id: keyboardTooltip
                    objectName: "keyboard-tooltip"
                    text: "Keyboard hint"
                    delay: 10
                }
            }
        }
    }

    Component {
        id: performanceWindow
        Window {
            width: 320
            height: 260
            visible: true
            Popouts.PerformancePopout {
                objectName: "performance-popout"
                maxWidth: 240
                maxHeight: 180
                status: ({vramTotal: 1000, vramUsed: 500})
                powerProfileStatus: ({profile: "balanced", capability: {ready: false, canChange: false}, profiles: []})
                vendorPerformanceStatus: ({profile: "balanced", capability: {canChange: false}, fanCurveCapability: {canChange: false}, fanCurveEnabled: false, profiles: []})
                gpuStatus: ({mode: "custom", capability: {canChange: false}, supportedModes: []})
                monitorStatus: ({monitors: Array.from({length: 8}, (_, index) => ({
                    name: "Monitor " + index,
                    canChange: true,
                    refreshId: "60",
                    refreshRate: 60,
                    rates: [{id: "60", label: "60 Hz"}]
                }))})
            }
        }
    }

    function cleanup() {
        if (testWindow) {
            testWindow.close();
            testWindow.destroy();
            testWindow = null;
        }
        if (actionsOwner) {
            actionsOwner.destroy();
            actionsOwner = null;
        }
    }

    function test_power_overlay_action_is_reachable_after_tab() {
        testWindow = controlWindow.createObject(testCase);
        tryCompare(testWindow, "visible", true);
        testWindow.requestActivate();
        tryCompare(testWindow, "active", true);
        const powerOverlay = findChild(testWindow, "powerOverlay");
        verify(powerOverlay);
        const lock = findChild(powerOverlay, "power-action-lock");
        verify(lock);
        tryCompare(powerOverlay, "activeFocus", true);
        verify(!lock.activeFocus);
        keyClick(Qt.Key_Tab);
        tryCompare(lock, "activeFocus", true);
        keyClick(Qt.Key_Return);
        compare(testWindow.powerAction, "lock");
        keyClick(Qt.Key_Escape);
        tryCompare(powerOverlay, "overlayOpen", false);
    }

    function test_power_overlay_shows_action_errors_and_disables_tiles_while_busy() {
        testWindow = controlWindow.createObject(testCase);
        const overlay = testWindow.powerOverlayRef;
        verify(overlay);
        const lock = findChild(overlay, "power-action-lock");
        verify(lock);
        const initialY = lock.y;
        const initialHeight = lock.height;
        overlay.actionError = "Power action failed: denied";
        const modal = findChild(overlay, "power-alert-modal");
        const status = findChild(overlay, "power-action-status");
        verify(modal);
        verify(status);
        tryCompare(modal, "visible", true);
        compare(status.text, "Power action failed: denied");
        compare(lock.y, initialY);
        compare(lock.height, initialHeight);
        compare(lock.enabled, false);
        overlay.actionError = "";
        overlay.actionBusy = true;
        compare(lock.enabled, false);
    }

    function test_power_overlay_badges_blocked_tiles_and_modal_override() {
        testWindow = controlWindow.createObject(testCase);
        testWindow.requestActivate();
        tryCompare(testWindow, "active", true);
        const overlay = testWindow.powerOverlayRef;
        verify(overlay);
        overlay.powerBlockers = {
            sleep: [{who: "T3 Code", why: "Agents are working", meta: "PID 578100"}],
            shutdown: [],
            micro: []
        };
        const sleepBadge = findChild(overlay, "power-badge-sleep");
        const hibernateBadge = findChild(overlay, "power-badge-hibernate");
        const lockBadge = findChild(overlay, "power-badge-lock");
        const shutdownBadge = findChild(overlay, "power-badge-shutdown");
        verify(sleepBadge && hibernateBadge && lockBadge && shutdownBadge);
        compare(sleepBadge.visible, true);
        compare(hibernateBadge.visible, true);
        compare(lockBadge.visible, false);
        compare(shutdownBadge.visible, false);

        overlay.actionAlert = {
            code: "inhibited",
            tone: "warning",
            title: "Sleep blocked",
            body: "An active app is keeping the laptop awake.",
            items: [{who: "T3 Code", why: "Agents are working", meta: "PID 578100"}],
            primaryLabel: "Sleep anyway",
            primaryKind: "force:sleep",
            primaryTone: "warning",
            secondaryLabel: "Cancel"
        };
        const primary = findChild(overlay, "power-alert-primary");
        verify(primary);
        tryCompare(primary, "visible", true);
        primary.clicked();
        compare(testWindow.powerAction, "force:sleep");

        // Escape dismisses the modal first without closing the power overlay.
        keyClick(Qt.Key_Escape);
        tryCompare(overlay, "hasAlert", false);
        compare(overlay.overlayOpen, true);
        keyClick(Qt.Key_Escape);
        tryCompare(overlay, "overlayOpen", false);
    }

    function test_busy_power_action_rejects_a_second_command_without_starting_a_process() {
        actionsOwner = actionsComponent.createObject(testCase);
        verify(actionsOwner);
        actionsOwner.powerBusy = true;
        const result = actionsOwner.runPower("fixture-command-must-not-run");
        compare(result.code, "busy");
        const process = findChild(actionsOwner, "power-action-process");
        verify(process);
        compare(process.running, false);
    }

    function test_system_section_button_accepts_keyboard_activation() {
        testWindow = controlWindow.createObject(testCase);
        testWindow.requestActivate();
        tryCompare(testWindow, "active", true);
        const section = findChild(testWindow, "system-section-audio");
        verify(section);
        section.forceActiveFocus();
        tryCompare(section, "activeFocus", true);
        keyClick(Qt.Key_Space);
        tryCompare(testWindow, "systemClicks", 1);
    }

    function test_system_slider_supports_arrow_page_and_home_keys() {
        testWindow = controlWindow.createObject(testCase);
        testWindow.requestActivate();
        tryCompare(testWindow, "active", true);
        const slider = findChild(testWindow, "system-slider");
        verify(slider);
        slider.forceActiveFocus();
        tryCompare(slider, "activeFocus", true);
        keyClick(Qt.Key_Right);
        tryCompare(testWindow, "sliderValue", 51);
        keyClick(Qt.Key_PageUp);
        tryCompare(testWindow, "sliderValue", 61);
        keyClick(Qt.Key_Home);
        tryCompare(testWindow, "sliderValue", 0);
    }

    function test_tooltip_opens_when_its_control_has_keyboard_focus() {
        testWindow = tooltipWindow.createObject(testCase);
        const control = findChild(testWindow, "keyboard-target");
        const tooltip = findChild(testWindow, "keyboard-tooltip");
        verify(control);
        verify(tooltip);
        control.forceActiveFocus();
        tryCompare(tooltip, "visible", true, 500);
        compare(testWindow.activeFocusItem, control);
    }

    function test_performance_panel_fits_and_scrolls_on_short_output() {
        testWindow = performanceWindow.createObject(testCase);
        testWindow.requestActivate();
        tryCompare(testWindow, "active", true);
        const performance = findChild(testWindow, "performance-popout");
        const scroll = findChild(performance, "performance-details-scroll");
        verify(performance);
        verify(scroll);
        tryCompare(performance, "height", 180);
        verify(scroll.contentHeight > scroll.height);
        scroll.forceActiveFocus();
        tryCompare(scroll, "activeFocus", true);
        keyClick(Qt.Key_End);
        verify(scroll.contentY > 0);
        keyClick(Qt.Key_Home);
        compare(scroll.contentY, 0);
    }
}
