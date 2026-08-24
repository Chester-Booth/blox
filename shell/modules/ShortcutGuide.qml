import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: root

    property bool armed: false
    property bool guideOpen: false
    property bool toggledOpen: false
    property bool rendered: false
    property var targetScreen: null
    property var targetMonitor: null
    property var targetWorkspace: null
    property var captureSource: null
    readonly property string wallpaperSource: Theme.wallpaperSource
    readonly property string wallpaperFit: Theme.wallpaperFit

    function focusedScreen() {
        for (const screen of Quickshell.screens) {
            if (Hyprland.monitorFor(screen) === Hyprland.focusedMonitor)
                return screen;

        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }

    function takeSnapshot() {
        Hyprland.refreshToplevels();
        targetScreen = focusedScreen();
        targetMonitor = targetScreen ? Hyprland.monitorFor(targetScreen) : null;
        targetWorkspace = targetMonitor ? targetMonitor.activeWorkspace : null;
        captureSource = targetScreen;
    }

    function arm() : string {
        if (guideOpen || armed)
            return "already armed";

        hideTimer.stop();
        takeSnapshot();
        rendered = true;
        armed = true;
        holdTimer.restart();
        return "armed";
    }

    function reveal() {
        rendered = true;
        guideOpen = true;
    }

    function delay() : string {
        if (!armed || guideOpen)
            return guideOpen ? "visible" : "inactive";

        holdTimer.restart();
        return "delayed";
    }

    function release() : string {
        armed = false;
        holdTimer.stop();
        if (toggledOpen)
            return "visible";

        close();
        return "hidden";
    }

    function cancel() : string {
        return close();
    }

    function close() : string {
        armed = false;
        holdTimer.stop();
        snapshotRevealTimer.stop();
        toggledOpen = false;
        guideOpen = false;
        hideTimer.restart();
        return "hidden";
    }

    function show() : string {
        armed = false;
        holdTimer.stop();
        takeSnapshot();
        rendered = true;
        snapshotRevealTimer.restart();
        return "visible";
    }

    function toggle() : string {
        if (toggledOpen)
            return close();

        toggledOpen = true;
        return show();
    }

    function status() : string {
        return JSON.stringify({
            "armed": armed,
            "visible": guideOpen,
            "rendered": rendered,
            "screen": targetScreen ? targetScreen.name : ""
        });
    }

    IpcHandler {
        function arm() : string {
            return root.arm();
        }

        function release() : string {
            return root.release();
        }

        function delay() : string {
            return root.delay();
        }

        function cancel() : string {
            return root.cancel();
        }

        function close() : string {
            return root.close();
        }

        function show() : string {
            return root.show();
        }

        function toggle() : string {
            return root.toggle();
        }

        function status() : string {
            return root.status();
        }

        target: "shortcutGuide"
    }

    Timer {
        id: holdTimer

        interval: 700
        repeat: false
        onTriggered: {
            if (root.armed)
                root.reveal();

        }
    }

    Timer {
        id: hideTimer

        interval: 200
        repeat: false
        onTriggered: {
            if (!root.guideOpen) {
                root.rendered = false;
                root.captureSource = null;
                root.targetMonitor = null;
                root.targetWorkspace = null;
            }
        }
    }

    Timer {
        id: snapshotRevealTimer

        interval: 120
        repeat: false
        onTriggered: root.reveal()
    }

    Variants {
        model: Quickshell.screens

        ShortcutGuideWindow {
            required property var modelData

            screen: modelData
            guideOpen: root.guideOpen && root.targetScreen === modelData
            interactive: root.toggledOpen && root.targetScreen === modelData
            rendered: root.rendered && root.targetScreen === modelData
            captureSource: root.captureSource
            captureMonitor: root.targetMonitor
            captureWorkspace: root.targetWorkspace
            wallpaperSource: root.wallpaperSource
            wallpaperFit: root.wallpaperFit
            onCloseRequested: root.close()
        }

    }

}
