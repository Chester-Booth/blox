import qs.shared
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "../shared/WidgetWorkArea.js" as WidgetWorkArea
import "../shared/OutputIdentity.js" as OutputIdentity

Scope {
    id: root

    property string openPanel: ""
    property string keyboardPanel: ""
    property real openPanelX: 8
    property real openPanelY: 8
    property var panelAnchorCandidates: ({})
    property var openPanelAnchorItem: null
    property string scriptRoot: Quickshell.shellDir + "/scripts"
    property bool barOpen: true
    property var outputOverrides: ({})
    property var edgeTriggerHoveredByOutput: ({})
    property var railSurfaceHoveredByOutput: ({})
    property var manualBarOpenByOutput: ({})
    property var fullscreenByOutput: ({})
    property string pendingEdgeReleaseOutput: ""
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
    readonly property int barDepth: Theme.railWidth + Math.max(0, Theme.barEdgeInset) * 2
    readonly property var occupiedBar: ({position: Theme.barPosition,
        extent: Theme.ready ? Math.round(barDepth * barSlide) : 0})
    readonly property int requestedExclusiveZone: Theme.ready && barPinnedOpen ? Math.round(barDepth * barSlide) : 0
    readonly property var reservationOutputs: Quickshell.screens.map(screen => screen.name).sort()
    readonly property string reservationKey: JSON.stringify([Theme.ready, Theme.barPosition, requestedExclusiveZone])
    readonly property bool exclusiveZoneAnimating: barPinnedOpen && barSlide > 0 && barSlide < 1
    property var externalReservationsByOutput: ({})
    property var presentedReservations: ({})
    property int reservationRevision: 0
    property int reservationAttempts: 0
    property var reservationObservation: null
    property bool reservationTimedOut: false
    property string reservationRaw: ""
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
    property var activeScreen: null
    readonly property bool horizontalBar: Theme.barPosition === "top" || Theme.barPosition === "bottom"
    readonly property var keyboardPanels: ["power", "system", "audio", "network", "bluetooth", "brightness", "notifications", "todo", "calendar", "updates", "privacy", "caffeine"]

    signal osdLevelPreview(string kind, int value, bool muted)

    // The bar owns one layer on every output. A frame after configuration gates
    // the first read and each changed request, including a reloaded layer.
    function barFrameSubmitted(output, key) {
        if (key !== reservationKey || presentedReservations[output] === key) return;
        const frames = Object.assign({}, presentedReservations);
        frames[output] = key;
        presentedReservations = frames;
        queueReservationObservation();
    }

    function reservationsConfigured() {
        return Theme.ready && reservationOutputs.length > 0 && !exclusiveZoneAnimating
            && reservationOutputs.every(output => presentedReservations[output] === reservationKey);
    }

    function queueReservationObservation() {
        if (reservationAttempts > 0 && reservationsConfigured() && !reservationObservation && !reservationQuery.running)
            reservationRefresh.restart();
    }

    function invalidateReservations() {
        reservationRevision++;
        reservationAttempts = 3;
        reservationRefresh.stop();
        reservationRetry.stop();
        queueReservationObservation();
    }

    function observeReservations() {
        if (!reservationsConfigured() || reservationObservation || reservationQuery.running || reservationAttempts <= 0) return false;
        reservationAttempts--;
        reservationObservation = {revision: reservationRevision, position: Theme.barPosition,
            extent: requestedExclusiveZone, outputs: reservationOutputs.slice()};
        reservationRaw = "";
        reservationTimedOut = false;
        reservationQuery.running = true;
        return true;
    }

    function finishReservationObservation(exitCode, exitStatus) {
        reservationWatchdog.stop();
        reservationKill.stop();
        const observation = reservationObservation;
        let external = null;
        if (observation && observation.revision === reservationRevision && !reservationTimedOut && exitCode === 0 && exitStatus === 0) {
            try {
                external = WidgetWorkArea.externalReservations(JSON.parse(reservationRaw), observation.outputs, observation);
            } catch (error) {}
        }
        reservationObservation = null;
        if (external !== null) {
            externalReservationsByOutput = external;
            reservationAttempts = 0;
        } else if (reservationAttempts > 0) {
            // A changed request waits for its own frame. Failed reads retry at
            // most twice; subsequent changes or compositor events re-arm them.
            reservationRetry.restart();
        }
    }

    onReservationKeyChanged: {
        presentedReservations = ({});
        invalidateReservations();
    }
    onReservationOutputsChanged: {
        // Hotplug does not repaint idle bars on unchanged outputs. Their last
        // frame still confirms the same request; only a new output needs one.
        const frames = {}, external = {};
        for (const output of reservationOutputs) {
            if (presentedReservations[output] !== undefined)
                frames[output] = presentedReservations[output];
            if (externalReservationsByOutput[output])
                external[output] = externalReservationsByOutput[output];
        }
        presentedReservations = frames;
        externalReservationsByOutput = external;
        invalidateReservations();
    }
    onExclusiveZoneAnimatingChanged: queueReservationObservation()

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (["monitoradded", "monitoraddedv2", "monitorremoved", "configreloaded", "openlayer", "closelayer"].indexOf(event.name) >= 0)
                root.invalidateReservations();
        }
    }

    Process {
        id: reservationQuery
        objectName: "bar-workarea-observation"
        command: ["hyprctl", "monitors", "-j"]
        onStarted: reservationWatchdog.restart()
        onExited: (exitCode, exitStatus) => root.finishReservationObservation(exitCode, exitStatus)
        stdout: StdioCollector { onStreamFinished: root.reservationRaw = this.text }
    }
    Timer {
        id: reservationRefresh
        interval: 0
        repeat: false
        onTriggered: root.observeReservations()
    }
    Timer {
        id: reservationRetry
        interval: 50
        repeat: false
        onTriggered: root.queueReservationObservation()
    }
    Timer {
        id: reservationWatchdog
        interval: 1500
        repeat: false
        onTriggered: {
            if (!reservationQuery.running) return;
            root.reservationTimedOut = true;
            reservationQuery.signal(15);
            reservationKill.restart();
        }
    }
    Timer {
        id: reservationKill
        interval: 250
        repeat: false
        onTriggered: { if (reservationQuery.running) reservationQuery.signal(9); }
    }

    function syncFullscreenByOutput(monitorsMap) {
        const next = {};
        if (monitorsMap && typeof monitorsMap === "object") {
            const keys = Object.keys(monitorsMap);
            for (let i = 0; i < keys.length; i++) {
                const name = keys[i];
                const entry = monitorsMap[name];
                if (entry && typeof entry === "object")
                    next[name] = entry.hasFullscreen === true;
            }
        }
        fullscreenByOutput = next;
    }

    function outputConfigFor(outputName) {
        const globalConfig = {
            bar: {
                visible: barOpen,
                position: Theme.barPosition,
                workspaceFilter: "this-display",
                showEmptyWorkspaces: true
            }
        };
        return OutputIdentity.resolveOutputConfig(globalConfig, outputOverrides, "", outputName || "");
    }

    function barPositionFor(outputName) {
        return outputConfigFor(outputName).bar.position;
    }

    function workspaceFilterFor(outputName) {
        return outputConfigFor(outputName).bar.workspaceFilter;
    }

    function showEmptyWorkspacesFor(outputName) {
        return outputConfigFor(outputName).bar.showEmptyWorkspaces;
    }

    function isManualBarOpen(outputName) {
        if (outputName && Object.prototype.hasOwnProperty.call(manualBarOpenByOutput, outputName))
            return manualBarOpenByOutput[outputName] === true;
        return outputConfigFor(outputName).bar.visible;
    }

    function setManualBarOpen(outputName, open) {
        const target = outputName || (activeScreen ? activeScreen.name : "");
        if (!target) {
            barOpen = !!open;
            return;
        }
        const next = Object.assign({}, manualBarOpenByOutput);
        next[target] = !!open;
        manualBarOpenByOutput = next;
        if (!open && activeScreen && activeScreen.name === target)
            closeBarOverlays();
    }

    function toggleManualBarOpen(outputName) {
        const target = outputName || (activeScreen ? activeScreen.name : "");
        setManualBarOpen(target, !isManualBarOpen(target));
    }

    function isFullscreenOn(outputName) {
        if (outputName && Object.prototype.hasOwnProperty.call(fullscreenByOutput, outputName))
            return fullscreenByOutput[outputName] === true;
        if (Quickshell.screens.length > 1 && outputName && activeScreen && activeScreen.name !== outputName)
            return false;
        return fullscreenActive;
    }

    function isBarPinnedOpen(outputName) {
        return isManualBarOpen(outputName) && !isFullscreenOn(outputName);
    }

    function isOutputOverlayActive(outputName) {
        if (outputName && activeScreen && activeScreen.name !== outputName)
            return false;
        return openPanel.length > 0 || trayOpen || trayMenuOpen || popoutHovered || trayHovered || trayBoundsHovered || inputPopupLocked;
    }

    function isHoverRevealHeld(outputName) {
        if (isBarPinnedOpen(outputName))
            return false;
        const edgeHeld = outputName ? (edgeTriggerHoveredByOutput[outputName] === true) : edgeTriggerHovered;
        const railHeld = outputName ? (railSurfaceHoveredByOutput[outputName] === true) : railSurfaceHovered;
        return edgeHeld || railHeld || isOutputOverlayActive(outputName);
    }

    function isBarVisible(outputName) {
        return isBarPinnedOpen(outputName) || isHoverRevealHeld(outputName);
    }

    function setRailSurfaceHovered(outputName, hovered) {
        if (outputName) {
            const next = Object.assign({}, railSurfaceHoveredByOutput);
            next[outputName] = !!hovered;
            railSurfaceHoveredByOutput = next;
        }
        railSurfaceHovered = !!hovered || Object.keys(railSurfaceHoveredByOutput).some(k => railSurfaceHoveredByOutput[k] === true);
    }

    function filterWorkspacesForOutput(items, outputName) {
        const list = Array.isArray(items) ? items : [];
        const filter = workspaceFilterFor(outputName);
        const showEmpty = showEmptyWorkspacesFor(outputName);
        const hasTaggedMonitors = outputName && list.some(item => item && item.monitor && item.monitor.length > 0);
        const result = [];
        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            if (!item)
                continue;
            if (filter === "this-display" && hasTaggedMonitors && item.monitor && item.monitor !== outputName)
                continue;
            const isActiveHere = item.activeOnMonitor !== undefined ? item.activeOnMonitor : item.active;
            if (!showEmpty && item.empty === true && !isActiveHere && !item.active && !item.urgent)
                continue;
            result.push(Object.assign({}, item, {active: !!(isActiveHere || item.active)}));
        }
        return result;
    }

    function enterEdgeTrigger(outputName) {
        edgeTriggerRelease.stop();
        if (outputName) {
            const next = Object.assign({}, edgeTriggerHoveredByOutput);
            next[outputName] = true;
            edgeTriggerHoveredByOutput = next;
        }
        edgeTriggerHovered = true;
    }

    function leaveEdgeTrigger(outputName) {
        pendingEdgeReleaseOutput = outputName || "";
        edgeTriggerRelease.restart();
    }

    function syncActiveScreenToFocus() {
        const screens = Quickshell.screens;
        if (Hyprland.focusedMonitor) {
            for (const screen of screens) {
                if (Hyprland.monitorFor(screen) === Hyprland.focusedMonitor) {
                    activeScreen = screen;
                    return;
                }
            }
        }

        // Focus and Qt outputs can become ready in either order at startup.
        // Keep a valid selection while focus is unavailable or an output leaves.
        if (screens.indexOf(activeScreen) < 0)
            activeScreen = screens.length > 0 ? screens[0] : null;
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (root.keyboardPanel.length === 0) {
                // List changes must not override a live pointer-owned output.
                if (Quickshell.screens.indexOf(root.activeScreen) >= 0)
                    return;
                root.closeBarOverlays();
            }
            root.syncActiveScreenToFocus();
        }
    }

    function closePanel() {
        openPanel = "";
        keyboardPanel = "";
        openPanelAnchorItem = null;
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

    function setPanelCentre(centre) {
        if (horizontalBar)
            openPanelX = centre;
        else
            openPanelY = centre;
    }

    function fallbackPanelCentre() {
        const target = activeScreen || (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null);
        if (!target)
            return 8;

        return horizontalBar ? target.width / 2 : target.height / 2;
    }

    function panelAnchor(panel) {
        const candidates = panelAnchorCandidates[panel] || [];
        let selected = null;
        let unscoped = null;
        for (const candidate of candidates) {
            if (activeScreen && candidate.screen === activeScreen) {
                if (!selected || candidate.priority > selected.priority)
                    selected = candidate;
            } else if (!candidate.screen && (!unscoped || candidate.priority > unscoped.priority)) {
                unscoped = candidate;
            }
        }
        return selected || unscoped;
    }

    function registerPanelAnchor(panel, item, centre, priority, screen) {
        if (typeof panel !== "string" || panel.length === 0 || !item || !Number.isFinite(Number(centre)))
            return ;

        const anchors = Object.assign({}, panelAnchorCandidates);
        const candidates = (anchors[panel] || []).slice();
        const index = candidates.findIndex((candidate) => candidate.item === item);
        const candidate = {
            item: item,
            centre: Number(centre),
            priority: Number(priority || 0),
            screen: screen || null
        };
        if (index >= 0)
            candidates[index] = candidate;
        else
            candidates.push(candidate);

        anchors[panel] = candidates;
        panelAnchorCandidates = anchors;

        if (openPanelAnchorItem === item) {
            setPanelCentre(Number(centre));
        } else if (openPanel === panel && keyboardPanel === panel && openPanelAnchorItem === null) {
            const activeAnchor = panelAnchor(panel);
            openPanelAnchorItem = activeAnchor ? activeAnchor.item : null;
            setPanelCentre(activeAnchor ? activeAnchor.centre : fallbackPanelCentre());
        }
    }

    function unregisterPanelAnchor(panel, item) {
        const candidates = panelAnchorCandidates[panel] || [];
        const remaining = candidates.filter((candidate) => candidate.item !== item);
        if (remaining.length === candidates.length)
            return ;

        const anchors = Object.assign({}, panelAnchorCandidates);
        if (remaining.length > 0)
            anchors[panel] = remaining;
        else
            delete anchors[panel];
        panelAnchorCandidates = anchors;

        if (openPanelAnchorItem === item) {
            const activeAnchor = panelAnchor(panel);
            openPanelAnchorItem = activeAnchor ? activeAnchor.item : null;
            setPanelCentre(activeAnchor ? activeAnchor.centre : fallbackPanelCentre());
        }
    }

    function reanchorKeyboardPanel() {
        if (keyboardPanel.length === 0 || openPanel.length === 0)
            return ;

        const anchor = panelAnchor(openPanel);
        openPanelAnchorItem = anchor ? anchor.item : null;
        setPanelCentre(anchor ? anchor.centre : fallbackPanelCentre());
    }

    function openHoverPanel(panel, centreY, anchorItem) {
        if (!activeScreen)
            syncActiveScreenToFocus();
        if (openPanel !== panel) {
            inputPopupLocked = false;
            keyboardPanel = "";
        }

        const registeredAnchor = centreY === undefined ? panelAnchor(panel) : null;
        const anchor = anchorItem ? {item: anchorItem, centre: centreY} : registeredAnchor;
        const centre = centreY !== undefined && Number.isFinite(Number(centreY)) ? Number(centreY)
            : anchor && Number.isFinite(Number(anchor.centre)) ? Number(anchor.centre) : fallbackPanelCentre();
        openPanelAnchorItem = anchor ? anchor.item : null;
        setPanelCentre(centre);
        openPanel = panel;
        hoverCloseDelay.stop();
    }

    function openKeyboardPanel(panel) {
        if (typeof panel !== "string" || keyboardPanels.indexOf(panel) < 0)
            return false;

        syncActiveScreenToFocus();
        openHoverPanel(panel);
        keyboardPanel = panel;
        hoverCloseDelay.stop();
        return true;
    }

    function panelState() {
        return {
            "openPanel": openPanel,
            "keyboardPanel": keyboardPanel,
            "keyboardOpen": keyboardPanel.length > 0
        };
    }

    function switchSystemPanel(panel) {
        if (["network", "bluetooth", "audio", "brightness"].indexOf(panel) < 0)
            return ;

        if (openPanel !== panel) {
            inputPopupLocked = false;
            if (keyboardPanel.length > 0)
                keyboardPanel = panel;
        }

        openPanel = panel;
        hoveredSource = "";
        hoverCloseDelay.stop();
    }

    function hoverButtonEntered(panel, centreY, source, anchorItem) {
        hoveredSource = source === undefined ? panel : source;
        openHoverPanel(panel, centreY, anchorItem);
    }

    function hoverButtonExited(source) {
        if (hoveredSource !== (source === undefined ? "" : source))
            return ;

        hoveredSource = "";
        scheduleHoverClose();
    }

    function scheduleHoverClose() {
        if (keyboardPanel.length > 0) {
            hoverCloseDelay.stop();
            return;
        }
        hoverCloseDelay.restart();
    }

    function trayEntered() {
        trayHovered = true;
        hoverCloseDelay.stop();
    }

    function trayItemEntered() {
        openPanel = "";
        keyboardPanel = "";
        openPanelAnchorItem = null;
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
        const wasOpen = trayMenuOpen;
        trayMenuOpen = false;
        trayMenuHandle = null;
        trayMenuTitle = "";
        if (wasOpen && !trayHovered && !trayBoundsHovered && !popoutHovered)
            scheduleHoverClose();
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
        if (horizontalBar) openPanelX = centreY;
        trayMenuOpen = !!(item.hasMenu || item.onlyMenu);
        hoverCloseDelay.stop();
        if (!trayMenuOpen)
            item.activate();

    }

    onActiveScreenChanged: reanchorKeyboardPanel()

    onBarOpenChanged: {
        if (!barOpen)
            closeBarOverlays();

    }
    onFullscreenActiveChanged: {
        if (fullscreenActive)
            closeBarOverlays();

    }
    Component.onCompleted: {
        invalidateReservations();
        Hyprland.refreshToplevels();
        syncActiveScreenToFocus();
    }

    IpcHandler {
        function open() : string {
            root.openKeyboardPanel("power");
            return "open";
        }

        function toggle() : string {
            if (root.openPanel === "power") {
                root.closePanel();
                return "closed";
            }
            root.openKeyboardPanel("power");
            return "open";
        }

        function close() : string {
            root.closePanel();
            return "closed";
        }

        target: "power"
    }

    IpcHandler {
        function open(section: string) : string {
            if (!root.openKeyboardPanel(section))
                return JSON.stringify({"ok": false, "code": "invalid-panel", "section": section});

            return JSON.stringify({"ok": true, "state": root.panelState()});
        }

        function close() : string {
            root.closePanel();
            return JSON.stringify({"ok": true, "state": root.panelState()});
        }

        function state() : string {
            return JSON.stringify(root.panelState());
        }

        target: "bar-panel"
    }

    Timer {
        id: hoverCloseDelay

        interval: 180
        repeat: false
        onTriggered: {
            if (root.keyboardPanel.length === 0 && root.hoveredSource.length === 0 && !root.popoutHovered && !root.trayHovered && !root.trayBoundsHovered && !root.trayMenuOpen && !root.inputPopupLocked) {
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
        onTriggered: {
            if (root.pendingEdgeReleaseOutput) {
                const next = Object.assign({}, root.edgeTriggerHoveredByOutput);
                next[root.pendingEdgeReleaseOutput] = false;
                root.edgeTriggerHoveredByOutput = next;
                root.pendingEdgeReleaseOutput = "";
                root.edgeTriggerHovered = Object.keys(next).some(k => next[k] === true);
            } else {
                root.edgeTriggerHoveredByOutput = ({});
                root.edgeTriggerHovered = false;
            }
        }
    }

    Behavior on barSlide {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
        }

    }

}
