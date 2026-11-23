import QtQuick
import Quickshell
import Quickshell.Hyprland

// Fixed compositor key events reuse the loaded owners without a CLI per repeat.
Scope {
    id: root

    property var audio: null
    property var brightness: null

    function handleHyprlandEvent(event) {
        if (!event || event.name !== "custom" || typeof event.data !== "string")
            return null;

        // No arguments or commands can be supplied by an event payload.
        switch (event.data) {
        case "blox_media_key>>volume-up": return root.audio.action("adjust-volume", "2");
        case "blox_media_key>>volume-down": return root.audio.action("adjust-volume", "-2");
        case "blox_media_key>>volume-mute": return root.audio.action("toggle-mute", "");
        case "blox_media_key>>mic-mute": return root.audio.action("toggle-mic", "");
        case "blox_media_key>>brightness-up": return root.brightness.action("adjust", "2");
        case "blox_media_key>>brightness-down": return root.brightness.action("adjust", "-2");
        default: return null;
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) { root.handleHyprlandEvent(event); }
    }
}
