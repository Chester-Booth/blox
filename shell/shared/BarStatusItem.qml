import QtQuick

Item {
    id: root

    required property string itemId
    required property BarItemContext context
    readonly property string panel: {
        const panels = {
            "wifi": "network",
            "sound": "audio",
            "privacy": "privacy",
            "awake": "caffeine",
            "display": "brightness",
            "bt": "bluetooth",
            "updates": "updates",
            "fan": "system",
            "gpu": "system"
        };
        return panels[itemId] || "";
    }
    readonly property string source: itemId

    function icon() {
        const content = context.contentController;
        if (itemId === "wifi")
            return content.network.json.icon || "󰤩";

        if (itemId === "sound")
            return content.audio.json.icon || "󰝾";

        if (itemId === "privacy")
            return content.privacy.json.icon || "󰝹";

        if (itemId === "awake")
            return content.caffeine.json.icon || "󰅶";

        if (itemId === "display")
            return content.brightness.json.icon || "󰃠";

        if (itemId === "bt")
            return content.bluetooth.json.icon || "󰂯";

        if (itemId === "updates")
            return content.updateIcon();

        if (itemId === "fan")
            return content.vendorPerformance.json.profile === "performance" ? "󱑬" : content.vendorPerformance.json.profile === "quiet" ? "󰠝" : "󱜝";

        if (itemId === "gpu")
            return content.gpu.json.mode === "eco" ? "󰌪" : content.gpu.json.mode === "gaming" ? "󰪫" : content.gpu.json.mode === "high-refresh" ? "" : "󰢮";

        return "";
    }

    function accent() {
        const content = context.contentController;
        if (itemId === "wifi")
            return content.network.json.class === "wifi" ? Theme.green : Theme.yellow;

        if (itemId === "sound")
            return content.audio.json.muted ? Theme.yellow : Theme.foreground;

        if (itemId === "privacy")
            return content.privacy.json.class === "active" ? Theme.yellow : Theme.foreground;

        if (itemId === "awake")
            return content.caffeine.json.active ? Theme.yellow : Theme.foreground;

        if (itemId === "display")
            return Theme.yellow;

        if (itemId === "bt")
            return content.bluetooth.json.class === "connected" ? Theme.blue : Theme.foreground;

        if (itemId === "updates")
            return content.updates.json.class === "zero" ? Theme.green : Theme.yellow;

        if (itemId === "fan")
            return content.vendorPerformance.json.profile === "performance" ? Theme.red : Theme.foreground;

        if (itemId === "gpu")
            return content.gpu.json.mode === "eco" ? Theme.green : Theme.yellow;

        return Theme.foreground;
    }

    function rightClick() {
        const content = context.contentController;
        if (itemId === "sound")
            content.run("pavucontrol -t 3");
        else if (itemId === "awake" && content.caffeine.json.capability && content.caffeine.json.capability.canChange === true)
            content.run(content.scriptRoot + "/status/caffeine.sh off");
        else if (itemId === "display" && content.brightness.json.capability && content.brightness.json.capability.canChange === true)
            content.run(content.scriptRoot + "/display/hyprsunset-toggle.sh");
        else if (itemId === "bt")
            content.run("blueman-manager");
    }

    implicitWidth: loader.item ? loader.item.implicitWidth : 0
    implicitHeight: loader.item ? loader.item.implicitHeight : 0

    Loader {
        id: loader

        sourceComponent: root.itemId === "touchpad" ? touchpadComponent : panelComponent
    }

    Component {
        id: panelComponent

        PanelRailButton {
            icon: root.icon()
            accent: root.accent()
            panel: root.panel
            source: root.source
            active: root.context.surfaceController.openPanel === panel
            onPanelClicked: (panel, centre) => {
                return root.context.surfaceController.openHoverPanel(panel, root.context.mappedCentre(this, centre));
            }
            onPanelHovered: (panel, centre, source) => {
                return root.context.surfaceController.hoverButtonEntered(panel, root.context.mappedCentre(this, centre), source);
            }
            onPanelExited: (source) => {
                return root.context.surfaceController.hoverButtonExited(source);
            }
            onRightClicked: root.rightClick()
        }

    }

    Component {
        id: touchpadComponent

        RailButton {
            icon: root.context.contentController.touchpad.json.icon || "󰟸"
            accent: root.context.contentController.touchpad.json.enabled === false ? Theme.yellow : Theme.foreground
            onHovered: root.context.surfaceController.trayEntered()
            onExited: root.context.surfaceController.trayExited()
            onClicked: {
                const status = root.context.contentController.touchpad.json;
                if (status.capability && status.capability.canChange === true)
                    root.context.contentController.touchpad.toggle();

            }
        }

    }

}
