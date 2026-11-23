import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.shared

// Public actions stay available before the Settings window is constructed.
// Keep the window after first use so drafts, preview restoration and Apply
// callbacks retain their existing owners.
Scope {
    id: root

    required property SettingsController settingsController
    readonly property var window: windowLoader.item

    Component.onCompleted: {
        SettingsApplyController.settingsProvider = settingsController;
        if (SettingsApplyController.quickWindowOpen) ensureWindow();
    }

    function ensureWindow() {
        if (!windowLoader.active) {
            windowLoader.setSource(Qt.resolvedUrl("../modules/SettingsWindow.qml"), {settingsController: root.settingsController});
            windowLoader.active = true;
        }
        return windowLoader.status === Loader.Ready ? windowLoader.item : null;
    }

    function openWindow() {
        const owner = ensureWindow();
        return owner ? owner.openWindow() : "unavailable";
    }

    function closeWindow() { return window ? window.closeWindow() : "closed"; }
    function toggle() { return window && window.windowOpen ? closeWindow() : openWindow(); }
    function status() {
        return window ? window.status() : JSON.stringify({open: false, category: "review", page: "landing", section: "", theme: ""});
    }
    function createFromWallpaper() {
        const owner = ensureWindow();
        return owner ? owner.createFromWallpaper() : "unavailable";
    }
    function openWidgetEditor(widgetId) {
        const owner = ensureWindow();
        return owner ? owner.openWidgetEditor(widgetId) : false;
    }
    function requestWidgetLayoutEdit() {
        const owner = ensureWindow();
        return owner ? owner.requestWidgetLayoutEdit() : false;
    }

    Loader {
        id: windowLoader
        active: false
        asynchronous: false
    }

    Connections {
        target: SettingsApplyController
        function onQuickWindowOpenChanged() {
            if (SettingsApplyController.quickWindowOpen) root.ensureWindow();
        }
    }

    Connections {
        target: Theme
        function onWidgetLayoutEditRequested() { root.requestWidgetLayoutEdit(); }
    }

    IpcHandler {
        objectName: "settings-ui-ipc"
        target: "settingsUi"
        function open() : string { return root.openWindow(); }
        function createFromWallpaper() : string { return root.createFromWallpaper(); }
        function close() : string { return root.closeWindow(); }
        function toggle() : string { return root.toggle(); }
        function status() : string { return root.status(); }
    }
}
