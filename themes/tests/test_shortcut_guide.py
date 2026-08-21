from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
MODULES = REPOSITORY / "shell/modules"


class ShortcutGuideSourceTests(unittest.TestCase):
    def test_toggle_bind_stays_open_after_super_release_and_accepts_clicks(self) -> None:
        controller = (MODULES / "ShortcutGuide.qml").read_text(encoding="utf-8")
        window = (MODULES / "ShortcutGuideWindow.qml").read_text(encoding="utf-8")

        # The Hyprland bind itself is user policy; the shell contract is the
        # toggle entry point and the documented key sequence.
        self.assertIn("function toggle() : string", controller)
        self.assertIn("if (toggledOpen)\n            return \"visible\";", controller)
        self.assertIn("interactive: root.toggledOpen", controller)
        self.assertIn("enabled: root.interactive", window)
        self.assertIn("onClicked: root.closeRequested()", window)
        self.assertIn('"keys": ["Shift", "/"]', window)

    def test_preview_composites_live_windows_over_a_frozen_screen(self) -> None:
        controller = (MODULES / "ShortcutGuide.qml").read_text(encoding="utf-8")
        window = (MODULES / "ShortcutGuideWindow.qml").read_text(encoding="utf-8")

        self.assertIn("captureSource = targetScreen;", controller)
        self.assertIn("targetWorkspace = targetMonitor ? targetMonitor.activeWorkspace : null;", controller)
        self.assertIn("readonly property string wallpaperSource: Theme.wallpaperSource", controller)
        self.assertIn("readonly property string wallpaperFit: Theme.wallpaperFit", controller)
        self.assertNotIn("Hyprland.activeToplevel", controller)
        self.assertIn("takeSnapshot();\n        rendered = true;", controller)
        self.assertIn("id: snapshotRevealTimer", controller)
        self.assertIn("live: false", window)
        self.assertIn("model: root.captureWorkspace ? root.captureWorkspace.toplevels : []", window)
        self.assertIn("captureSource: liveToplevel.modelData.wayland", window)
        self.assertIn("live: true", window)
        self.assertIn('Qt.formatTime(previewClock.date, "hh:mm:ss AP")', window)
        live_toplevel = window.split("id: liveToplevel", 1)[1].split("ScreencopyView {", 1)[0]
        self.assertIn("source: root.wallpaperSource", live_toplevel)
        self.assertIn("x: -liveToplevel.x", live_toplevel)
        self.assertIn('fragmentShader: "../assets/shaders/window-content.frag.qsb"', window)
        self.assertIn("Math.round(width * root.captureMonitor.height / root.captureMonitor.width)", window)
        self.assertIn("textureSize: Qt.size(", window)
        self.assertIn("mipmap: true", window)

    def test_move_window_hint_matches_the_other_explanatory_text(self) -> None:
        window = (MODULES / "ShortcutGuideWindow.qml").read_text(encoding="utf-8")
        hint = window.split('text: "Move window"', 1)[1].split("}", 1)[0]

        self.assertIn("font.family: Theme.bodyFontFamily", hint)
        self.assertIn("font.pixelSize: 20", hint)
        focus_hint = window.split('text: "Focus direction"', 1)[1].split("}", 1)[0]
        self.assertIn("font.pixelSize: 20", focus_hint)
        move_block = window.split("id: moveWindowShortcuts", 1)[1].split("IconShortcutRow {", 1)[0]
        self.assertIn('iconName: "mouse-left-click"', move_block)
        self.assertIn('text: "Move window"', move_block)
        self.assertIn("x: moveWindowShortcuts.x", window)
        self.assertNotIn('text: "moves window"', window)
        self.assertIn('source: iconName === "" ? "" : "../assets/phosphor/" + iconName + ".svg"', window)
        pointer_keys = window.split("component PointerShortcutKeys: Row", 1)[1].split("component IconShortcutRow", 1)[0]
        self.assertIn('text: "+"', pointer_keys)
        self.assertIn('iconName: "cursor"', pointer_keys)


if __name__ == "__main__":
    unittest.main()
