//@ pragma IconTheme Adwaita

import "./modules"
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool barOpen: true

    IpcHandler {
        function toggle() : string {
            root.barOpen = !root.barOpen;
            return root.barOpen ? "visible" : "hidden";
        }

        target: "bar"
    }

    Bar {
        id: bar

        barOpen: root.barOpen
    }

    Connections {
        function onOsdLevelPreview(kind, value, muted) {
            return osd.preview(kind, value, muted);
        }

        target: bar.controller
    }

    Osd {
        id: osd
    }

    Wallpaper {
    }

    DesktopWidgets {
    }

    ThemePicker {
    }

    ShortcutGuide {
    }

    Launcher {
    }

}
