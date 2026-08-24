import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: root

    property string openPanel: ""
    property real openPanelX: 8
    property real openPanelY: 8
    property string scriptRoot: Quickshell.shellDir + "/scripts"
    property bool barOpen: true
    property bool edgeTriggerHovered: false
    property bool railSurfaceHovered: false
    readonly property var activeToplevelState: Hyprland.activeToplevel ? Hyprland.activeToplevel.lastIpcObject || ({
    }) : ({
    })
    readonly property var activeWaylandToplevel: ToplevelManager.activeToplevel
    readonly property bool fullscreenActive: activeWaylandToplevel ? activeWaylandToplevel.fullscreen : Number(activeToplevelState.fullscreen || 0) > 0
    readonly property bool barPinnedOpen: barOpen && !fullscreenActive
    readonly property bool hoverRevealHeld: !barPinnedOpen && (edgeTriggerHovered || railSurfaceHovered || openPanel.length > 0 || trayOpen || trayMenuOpen || popoutHovered || trayHovered || trayBoundsHovered || inputPopupLocked)
    readonly property bool barVisible: barPinnedOpen || hoverRevealHeld
    property real barSlide: barVisible ? 1 : 0
    property bool trayOpen: false
    property string hoveredSource: ""
    property bool popoutHovered: false
    property bool trayHovered: false
    property bool trayBoundsHovered: false
    property bool inputPopupLocked: false
    property var trayMenuHandle: null
    property string trayMenuTitle: ""
    property real trayMenuY: 8
    property bool trayMenuOpen: false
    property var activeScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    readonly property bool horizontalBar: Theme.barPosition === "top" || Theme.barPosition === "bottom"

    signal osdLevelPreview(string kind, int value, bool muted)

    function enterEdgeTrigger() {
        edgeTriggerRelease.stop();
        edgeTriggerHovered = true;
    }

    function leaveEdgeTrigger() {
        edgeTriggerRelease.restart();
    }

    function syncActiveScreenToFocus() {
        if (!Hyprland.focusedMonitor)
            return ;

        for (let i = 0; i < Quickshell.screens.length; i++) {
            const screen = Quickshell.screens[i];
            if (Hyprland.monitorFor(screen) === Hyprland.focusedMonitor) {
                activeScreen = screen;
                return ;
            }
        }
    }

    function closePanel() {
        openPanel = "";
        hoveredSource = "";
        popoutHovered = false;
        trayHovered = false;
        inputPopupLocked = false;
        hoverCloseDelay.stop();
    }

    function setInputPopupLocked(locked) {
        inputPopupLocked = locked;
        if (locked)
            hoverCloseDelay.stop();
        else if (hoveredSource.length === 0 && !popoutHovered)
            scheduleHoverClose();
    }

    function openHoverPanel(panel, centreY) {
        if (openPanel !== panel)
            inputPopupLocked = false;

        if (horizontalBar)
            openPanelX = centreY === undefined ? 8 : centreY;
        else
            openPanelY = centreY === undefined ? 8 : centreY;
        openPanel = panel;
        hoverCloseDelay.stop();
    }

    function switchSystemPanel(panel) {
        if (["network", "bluetooth", "audio", "brightness"].indexOf(panel) < 0)
            return ;

        if (openPanel !== panel)
            inputPopupLocked = false;

        openPanel = panel;
        hoveredSource = "";
        hoverCloseDelay.stop();
    }

    function hoverButtonEntered(panel, centreY, source) {
        hoveredSource = source === undefined ? panel : source;
        openHoverPanel(panel, centreY);
    }

    function hoverButtonExited(source) {
        if (hoveredSource !== (source === undefined ? "" : source))
            return ;

        hoveredSource = "";
        scheduleHoverClose();
    }

    function scheduleHoverClose() {
        hoverCloseDelay.restart();
    }

    function trayEntered() {
        trayHovered = true;
        hoverCloseDelay.stop();
    }

    function trayItemEntered() {
        openPanel = "";
        hoveredSource = "";
        popoutHovered = false;
        inputPopupLocked = false;
        trayEntered();
    }

    function trayExited() {
        trayHovered = false;
        scheduleHoverClose();
    }

    function trayBoundsEntered() {
        trayBoundsHovered = true;
        hoverCloseDelay.stop();
    }

    function trayBoundsExited() {
        trayBoundsHovered = false;
        scheduleHoverClose();
    }

    function popoutEntered() {
        popoutHovered = true;
        hoverCloseDelay.stop();
    }

    function popoutExited() {
        popoutHovered = false;
        scheduleHoverClose();
    }

    function closeTrayMenu() {
        trayMenuOpen = false;
        trayMenuHandle = null;
        trayMenuTitle = "";
    }

    function toggleTray() {
        closePanel();
        closeTrayMenu();
        trayOpen = !trayOpen;
        trayHovered = trayOpen;
    }

    function openTray() {
        if (trayOpen)
            return ;

        closePanel();
        closeTrayMenu();
        trayOpen = true;
    }

    function closeBarOverlays() {
        closePanel();
        closeTrayMenu();
        trayHovered = false;
        trayBoundsHovered = false;
        trayOpen = false;
    }

    function openTrayMenu(item, centreY) {
        closePanel();
        trayOpen = true;
        trayHovered = true;
        trayMenuHandle = item.menu;
        trayMenuTitle = item.tooltipTitle || item.title || item.id || "Tray";
        trayMenuY = centreY;
        trayMenuOpen = !!(item.hasMenu || item.onlyMenu);
        if (!trayMenuOpen)
            item.activate();

    }

    onBarOpenChanged: {
        if (!barOpen)
            closeBarOverlays();

    }
    onFullscreenActiveChanged: {
        if (fullscreenActive)
            closeBarOverlays();

    }
    Component.onCompleted: {
        Hyprland.refreshToplevels();
        syncActiveScreenToFocus();
    }

    IpcHandler {
        function open() : string {
            root.openHoverPanel("power", root.openPanelY);
            return "open";
        }

        function toggle() : string {
            if (root.openPanel === "power") {
                root.closePanel();
                return "closed";
            }
            root.openHoverPanel("power", root.openPanelY);
            return "open";
        }

        function close() : string {
            root.closePanel();
            return "closed";
        }

        target: "power"
    }

    Timer {
        id: hoverCloseDelay

        interval: 180
        repeat: false
        onTriggered: {
            if (root.hoveredSource.length === 0 && !root.popoutHovered && !root.trayHovered && !root.trayBoundsHovered && !root.inputPopupLocked) {
                root.closePanel();
                root.closeTrayMenu();
                root.trayOpen = false;
            }
        }
    }

    Timer {
        id: edgeTriggerRelease

        interval: 140
        repeat: false
        onTriggered: root.edgeTriggerHovered = false
    }

    Behavior on barSlide {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
        }

    }

}
