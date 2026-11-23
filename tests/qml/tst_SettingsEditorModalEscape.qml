import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtTest
import qs.modules

TestCase {
    id: testCase
    name: "SettingsEditorModalEscape"
    when: windowShown
    property var window: null

    Component {
        id: fixture
        Window {
            id: fixtureWindow
            visible: true
            width: 680
            height: 480
            property alias controller: editorController
            property alias modal: editorModal
            property alias returnTarget: returnTarget

            function focusModal() { editorModal.forceActiveFocus(); }

            SettingsThemeEditorController {
                id: editorController
                host: fixtureWindow
            }

            Item {
                id: fixtureHost
                anchors.fill: parent

                TextField {
                    id: returnTarget
                    objectName: "settings-return-target"
                    anchors.centerIn: parent
                    text: "Fixture focus target"
                    activeFocusOnTab: true
                }

                SettingsEditorModal {
                    id: editorModal
                    anchors.fill: parent
                    controller: editorController
                }
            }
        }
    }

    function init() {
        window = fixture.createObject(testCase);
        verify(window);
        wait(30);
    }

    function cleanup() {
        if (window) {
            window.close();
            window.destroy();
            window = null;
        }
    }

    function openDirtyNavigationModal() {
        window.controller.candidate = ({id: "fixture", name: "Fixture", value: "changed"});
        window.controller.baselineJson = JSON.stringify({id: "fixture", name: "Fixture", value: "original"});
        verify(window.controller.dirty);
        window.returnTarget.forceActiveFocus();
        tryCompare(window.returnTarget, "activeFocus", true);
        window.controller.overlayFocusTarget = window.returnTarget;
        window.controller.showModal("navigate");
        tryCompare(window.controller, "modalKind", "navigate");
        tryCompare(window.modal, "visible", true);
        tryCompare(window.modal, "activeFocus", true);
    }

    function test_escape_waits_for_modal_timer_and_restores_overlay_target() {
        openDirtyNavigationModal();
        keyClick(Qt.Key_Escape);
        tryCompare(window.controller, "modalKind", "", 1000);
        tryCompare(window.returnTarget, "activeFocus", true, 1000);
        verify(window.controller.dirty);
        compare(window.controller.pendingModalConfirmation, "");
        compare(window.controller.pendingPreviewContinuation, "");
    }

    function test_escape_restores_focus_captured_from_native_window() {
        window.controller.candidate = ({id: "fixture", name: "Fixture", value: "changed"});
        window.controller.baselineJson = JSON.stringify({id: "fixture", name: "Fixture", value: "original"});
        verify(window.controller.dirty);
        window.controller.overlayFocusTarget = null;
        window.returnTarget.forceActiveFocus();
        tryCompare(window.returnTarget, "activeFocus", true);

        const nativeWindow = window.contentItem.Window.window;
        verify(nativeWindow);
        tryCompare(nativeWindow, "activeFocusItem", window.returnTarget);
        window.controller.showModal("navigate");
        tryCompare(window.controller, "modalKind", "navigate");
        tryCompare(window.modal, "visible", true);
        tryCompare(window.modal, "activeFocus", true);
        verify(window.controller.focusBeforeOverlay === window.returnTarget);

        keyClick(Qt.Key_Escape);
        tryCompare(window.controller, "modalKind", "", 1000);
        tryCompare(window.returnTarget, "activeFocus", true, 1000);
        tryCompare(nativeWindow, "activeFocusItem", window.returnTarget, 1000);
        verify(window.controller.dirty);
        compare(window.controller.overlayFocusTarget, null);
    }

    function test_escape_is_consumed_while_controller_is_busy() {
        window.controller.busy = true;
        openDirtyNavigationModal();
        keyClick(Qt.Key_Escape);
        wait(120);
        compare(window.controller.modalKind, "navigate");
        window.controller.busy = false;
        keyClick(Qt.Key_Escape);
        tryCompare(window.controller, "modalKind", "", 1000);
        tryCompare(window.returnTarget, "activeFocus", true, 1000);
    }
}
