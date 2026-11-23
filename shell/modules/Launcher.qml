import qs.shared
import qs.services
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
    id: root

    property string activeSurface: "idle"
    property var targetScreen: null
    property bool clipboardPositionReady: false
    property bool emojiPositionReady: false

    // Construct closed so the first open runs the same refresh/focus handlers
    // as later opens. These synchronous loaders stay active after first use.
    function ensureSurface(surface) {
        if (surface === "main" || surface === "dmenu")
            mainSurfaceLoader.active = true;
        else if (surface === "clipboard")
            clipboardLoader.active = true;
        else if (surface === "emoji")
            emojiLoader.active = true;
    }

    function focusedScreen() {
        for (const screen of Quickshell.screens) if (Hyprland.monitorFor(screen) === Hyprland.focusedMonitor) {
            return screen;
        }
        return Quickshell.screens.length ? Quickshell.screens[0] : null;
    }

    function requestedScreen(value) {
        if (!String(value || "").length)
            return focusedScreen();

        const number = Number(value);
        for (let index = 0; index < Quickshell.screens.length; index++) {
            const screen = Quickshell.screens[index];
            if (screen.name === value || (!isNaN(number) && index === number))
                return screen;

        }
        return focusedScreen();
    }

    function show(surface) {
        targetScreen = focusedScreen();
        const opening = activeSurface !== surface;
        if (activeSurface === "idle")
            pasteController.captureTarget();

        if (opening && surface === "clipboard") {
            clipboardPositionReady = false;
            positionFallback.restart();
        } else if (opening && surface === "emoji") {
            emojiPositionReady = false;
            positionFallback.restart();
        } else if (!opening) {
            positionFallback.stop();
        }
        if (opening)
            ensureSurface(surface);
        activeSurface = activeSurface === surface ? "idle" : surface;
        return activeSurface;
    }

    function close() {
        positionFallback.stop();
        if (activeSurface === "dmenu") {
            dmenu.finish("", true);
            mainController.dmenuMode = false;
            mainController.dmenuPrompt = "";
        }
        activeSurface = "idle";
        return "idle";
    }

    Process {
        id: windowState

        readonly property string bloxd: Quickshell.shellDir + "/native/qml/Blox/Services/bloxd"

        command: [bloxd, "window-state"]
        stdinEnabled: true
        environment: ({BLOX_IPC_SCRIPT: Quickshell.shellDir + "/scripts/ipc.sh"})
        running: true
        onExited: windowStateRestart.restart()
    }

    Timer {
        id: windowStateRestart

        interval: 1000
        onTriggered: {
            windowState.running = true;
        }
    }

    Timer {
        id: positionFallback

        interval: 900
        onTriggered: {
            if (root.activeSurface === "clipboard")
                root.clipboardPositionReady = true;
            else if (root.activeSurface === "emoji")
                root.emojiPositionReady = true;
        }
    }

    IpcHandler {
        function main() : string {
            return root.show("main");
        }

        function clipboard() : string {
            return root.show("clipboard");
        }

        function emoji() : string {
            return root.show("emoji");
        }

        function close() : string {
            return root.close();
        }

        function status() : string {
            return JSON.stringify({
                "surface": root.activeSurface,
                "screen": root.targetScreen ? root.targetScreen.name : "",
                "clipboard_healthy": watcher.healthy
            });
        }

        function positioned(surface: string) : string {
            if (surface === "clipboard")
                root.clipboardPositionReady = true;
            else if (surface === "emoji")
                root.emojiPositionReady = true;
            if (root.activeSurface === surface)
                positionFallback.stop();

            return surface;
        }

        target: "launcher"
    }

    LauncherMainController {
        id: mainController

        onCloseRequested: root.close()
        onDismissRequested: mainFocusReturn.dismiss()
        onThemeApplyStarted: root.close()
    }

    LauncherMainFocusReturn {
        id: mainFocusReturn

        targetController: pasteController
        onCloseRequested: root.close()
    }

    ClipboardController {
        id: clipboardController

        onCloseRequested: root.close()
        onDismissRequested: { pasteController.restoreTarget(); root.close(); }
        onPasteRequested: pasteController.pasteWhenRestored()
    }

    EmojiController {
        id: emojiController

        onCloseRequested: root.close()
        onDismissRequested: { pasteController.restoreTarget(); root.close(); }
        onPasteRequested: pasteController.pasteWhenRestored()
    }

    PasteController {
        id: pasteController

        tracking: root.activeSurface === "clipboard" || root.activeSurface === "emoji"
        onCloseRequested: root.close()
    }

    DmenuServer {
        id: dmenu

        onRequest: (options, prompt, query, settings) => {
            if (root.activeSurface === "idle")
                pasteController.captureTarget();
            root.targetScreen = root.requestedScreen(settings.monitor);
            mainController.dmenuMode = true;
            mainController.dmenuOptions = options;
            mainController.dmenuPrompt = prompt;
            mainController.dmenuInsensitive = settings.insensitive;
            mainController.dmenuLimit = settings.lines;
            mainController.dmenuBottom = settings.bottom;
            mainController.query = query;
            mainController.refresh();
            root.ensureSurface("dmenu");
            root.activeSurface = "dmenu";
        }
        onUpdated: (options) => {
            mainController.dmenuOptions = options;
            mainController.refresh();
        }
        onAbandoned: {
            mainController.dmenuMode = false;
            mainController.dmenuPrompt = "";
            if (root.activeSurface === "dmenu")
                root.close();

        }
    }

    Connections {
        function onDmenuSelected(value) {
            dmenu.finish(value, false);
            mainController.dmenuMode = false;
            mainController.dmenuPrompt = "";
            mainFocusReturn.selectDmenu();
        }

        target: mainController
    }

    ClipboardWatcher {
        id: watcher
    }

    Loader {
        id: mainSurfaceLoader
        active: false
        asynchronous: false
        sourceComponent: LauncherMainSurface {
            controller: mainController
            targetScreen: root.targetScreen
            open: root.activeSurface === "main" || root.activeSurface === "dmenu"
        }
    }

    Loader {
        id: quickApplyLoader
        active: false
        asynchronous: false
        sourceComponent: LauncherThemeApplyWindow {
            controller: mainController
            targetScreen: root.targetScreen
        }
    }

    Connections {
        target: SettingsApplyController
        function onQuickWindowOpenChanged() {
            if (SettingsApplyController.quickWindowOpen)
                quickApplyLoader.active = true;
        }
    }

    Component.onCompleted: {
        if (SettingsApplyController.quickWindowOpen)
            quickApplyLoader.active = true;
    }

    Loader {
        id: clipboardLoader
        active: false
        asynchronous: false
        sourceComponent: ClipboardPicker {
            controller: clipboardController
            positionReady: root.clipboardPositionReady
            watcherHealthy: watcher.healthy
            targetScreen: root.targetScreen
            open: root.activeSurface === "clipboard"
        }
    }

    Loader {
        id: emojiLoader
        active: false
        asynchronous: false
        sourceComponent: EmojiPicker {
            controller: emojiController
            positionReady: root.emojiPositionReady
            targetScreen: root.targetScreen
            open: root.activeSurface === "emoji"
        }
    }

}
