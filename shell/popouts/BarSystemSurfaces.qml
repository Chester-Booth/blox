import qs.services
import qs.shared
import QtQuick

Item {
    id: root

    required property BarPopoutGeometry geometry
    required property BarSurfaceController surfaceController
    required property BarContentController contentController
    required property UiState uiState

    function runSystemAction(command, keepOpen) {
        contentController.run(command);
        contentController.audio.refresh();
        contentController.brightness.refresh();
        contentController.bluetooth.refresh();
        contentController.network.refresh();
        if (!keepOpen)
            surfaceController.closePanel();

    }

    HoverPopupWindow {
        anchorWindow: root.geometry.panelWindow
        anchorX: Theme.barPosition === "top" || Theme.barPosition === "bottom" ? root.geometry.adjacentPopupX(mediaPlayer.implicitWidth, systemWindow.anchorX, systemPopout.width) : root.geometry.popupX(mediaPlayer.implicitWidth, root.geometry.openPanelX)
        anchorY: Theme.barPosition === "left" || Theme.barPosition === "right" ? Math.max(8, systemWindow.anchorY - mediaPlayer.implicitHeight - 8) : root.geometry.popupY(mediaPlayer.implicitHeight, root.geometry.openPanelY)
        contentWidth: 330
        contentHeight: mediaPlayer.implicitHeight
        open: root.geometry.active && root.surfaceController.openPanel === "audio" && mediaPlayer.hasPlayers
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()

        MediaPlayer {
            id: mediaPlayer

            width: 330
            activePlayerName: root.uiState.activeMprisPlayer
            onSelectPlayer: (playerName) => {
                root.uiState.activeMprisPlayer = playerName;
            }
        }

    }

    HoverPopupWindow {
        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(performancePopout.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(performancePopout.height, root.geometry.openPanelY)
        contentWidth: performancePopout.width
        contentHeight: performancePopout.height
        open: root.geometry.active && root.surfaceController.openPanel === "system"
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()
        onVisibleChanged: {
            if (root.geometry.active)
                root.contentController.setPerformancePolling(visible);

        }

        PerformancePopout {
            id: performancePopout

            status: root.contentController.systemInfo.json || ({
            })
            batteryStatus: root.contentController.battery.json || ({
            })
            scriptRoot: root.surfaceController.scriptRoot
            actionBusy: root.contentController.actions.performanceBusy
            actionError: root.contentController.actions.performanceError
            statusError: root.contentController.statusError("system")
            onAction: (command) => {
                root.contentController.runPerformance(command);
            }
        }

    }

    HoverPopupWindow {
        id: systemWindow

        anchorWindow: root.geometry.panelWindow
        anchorX: root.geometry.popupX(systemPopout.width, root.geometry.openPanelX)
        anchorY: root.geometry.popupY(systemPopout.height, root.geometry.openPanelY)
        contentWidth: systemPopout.width
        contentHeight: systemPopout.height
        open: root.geometry.active && ["audio", "network", "bluetooth", "brightness"].indexOf(root.surfaceController.openPanel) >= 0
        onHoverEntered: root.surfaceController.popoutEntered()
        onHoverExited: root.surfaceController.popoutExited()
        onVisibleChanged: {
            if (!visible && root.geometry.active && ["audio", "network", "bluetooth", "brightness"].indexOf(root.surfaceController.openPanel) >= 0)
                root.surfaceController.closePanel();

        }

        SystemPopout {
            id: systemPopout

            title: root.contentController.content.systemPanelTitle()
            body: root.contentController.content.systemPanelBody()
            statusError: root.contentController.statusError(root.surfaceController.openPanel)
            actions: root.contentController.content.systemPanelActions()
            mode: root.surfaceController.openPanel
            audioVolume: root.contentController.audio.json.volume || 0
            audioIcon: root.contentController.audio.json.icon || "󰕾"
            audioMuted: !!root.contentController.audio.json.muted
            micMuted: !!root.contentController.audio.json.micMuted
            audioCanChange: !!(root.contentController.audio.json.capability && root.contentController.audio.json.capability.canChange === true)
            micCanChange: root.contentController.audio.json.micCanChange === undefined ? !!(root.contentController.audio.json.capability && root.contentController.audio.json.capability.canChange === true) : root.contentController.audio.json.micCanChange === true
            audioProvider: root.contentController.audio
            networkEnabled: root.contentController.network.json.class !== "disabled"
            networkCanChange: !!(root.contentController.network.json.capability && root.contentController.network.json.capability.canChange === true)
            bluetoothEnabled: root.contentController.bluetooth.json.class !== "disabled"
            bluetoothCanChange: !!(root.contentController.bluetooth.json.capability && root.contentController.bluetooth.json.capability.canChange === true)
            wifiIcon: root.contentController.network.json.icon || "󰤩"
            wifiText: root.contentController.network.json.ssid || root.contentController.network.json.class || "Wi-Fi"
            bluetoothIcon: root.contentController.bluetooth.json.icon || "󰂯"
            brightnessIcon: root.contentController.brightness.json.icon || "󰃠"
            brightnessPercent: root.contentController.brightness.json.percent || 0
            brightnessCanChange: !!(root.contentController.brightness.json.capability && root.contentController.brightness.json.capability.canChange === true)
            blueLightMode: root.contentController.brightness.json.blueLightMode || "auto"
            blueLightActive: !!root.contentController.brightness.json.blueLightActive
            scriptRoot: root.surfaceController.scriptRoot
            onAction: (command, keepOpen) => {
                root.runSystemAction(command, keepOpen);
            }
            onLevelPreview: (kind, value, muted) => {
                root.surfaceController.osdLevelPreview(kind, value, muted);
            }
            onSectionSelected: (panel) => {
                root.surfaceController.switchSystemPanel(panel);
            }
        }

    }

}
