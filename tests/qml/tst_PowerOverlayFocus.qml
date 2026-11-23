import QtQuick
import QtQuick.Window
import QtTest
import "../../shell/popouts" as Popouts
import "../../shell/services" as Services

TestCase {
    id: testCase
    name: "PowerOverlayFocus"
    when: windowShown
    property var window

    Component {
        id: fixture
        Window {
            width: 1000
            height: 700
            visible: true
            property alias overlay: overlay
            property alias controller: controller
            property int actions: 0
            Services.BarSurfaceController { id: controller }
            Popouts.PowerOverlay {
                id: overlay
                anchors.fill: parent
                openAnimationDuration: 0
                overlayOpen: controller.openPanel === "power"
                onClose: controller.closePanel()
                onAction: window.actions++
            }
        }
    }

    function init() { window = createTemporaryObject(fixture, testCase); }

    function visualChild(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const match = visualChild(child, name);
            if (match) return match;
        }
        return null;
    }

    function test_focusStartsOnFirstTabAndResetsOnReopen() {
        const first = visualChild(window.contentItem, "power-action-lock");
        verify(first !== null);
        window.overlay.overlayOpen = true;
        tryCompare(window.overlay, "activeFocus", true);
        verify(!first.activeFocus);
        keyClick(Qt.Key_Return);
        compare(window.actions, 0);
        keyClick(Qt.Key_Tab);
        tryCompare(first, "activeFocus", true);
        window.overlay.overlayOpen = false;
        window.overlay.overlayOpen = true;
        tryCompare(window.overlay, "activeFocus", true);
        verify(!first.activeFocus);
        keyClick(Qt.Key_Tab);
        tryCompare(first, "activeFocus", true);
    }

    function test_ipcOpenFocusTabEscapeAndToggleReopenWithoutPointer() {
        let ipc = null;
        for (const child of window.controller.data) {
            if (child.target === "power") ipc = child;
        }
        verify(ipc !== null);
        const first = visualChild(window.contentItem, "power-action-lock");
        compare(ipc.toggle(), "open");
        tryCompare(window.overlay, "activeFocus", true);
        keyClick(Qt.Key_Return);
        compare(window.actions, 0);
        keyClick(Qt.Key_Tab);
        tryCompare(first, "activeFocus", true);
        keyClick(Qt.Key_Escape);
        compare(window.controller.openPanel, "");
        compare(window.controller.keyboardPanel, "");
        compare(ipc.toggle(), "open");
        tryCompare(window.overlay, "activeFocus", true);
        verify(!first.activeFocus);
        keyClick(Qt.Key_Tab);
        tryCompare(first, "activeFocus", true);
        compare(ipc.toggle(), "closed");
        verify(!window.overlay.overlayOpen);
        compare(window.controller.keyboardPanel, "");
        compare(window.actions, 0);
    }

}
