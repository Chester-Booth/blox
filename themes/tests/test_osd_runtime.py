from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]


class OsdRuntimeTests(unittest.TestCase):
    def test_osd_surface_is_bounded_and_click_through(self) -> None:
        source = (
            REPOSITORY / "shell/modules/OsdSurface.qml"
        ).read_text(encoding="utf-8")
        window = source.split("id: osdWindow", 1)[1]

        self.assertIn("implicitWidth: 292 +", window)
        self.assertIn("implicitHeight: 72 + restingGap", window)
        self.assertIn("Item {\n                id: osdPopup", window)
        self.assertIn(
            "y: osdWindow.onTop ? osdWindow.restingGap : 0", window
        )
        self.assertIn("-osdCard.height - osdWindow.restingGap", window)
        self.assertIn("osdWindow.height", window)
        self.assertNotIn("PopupWindow {", window)
        self.assertNotIn("modelData.width", window)
        self.assertNotIn("modelData.height", window)
        self.assertIn("left: onLeft", window)
        self.assertIn("right: onRight", window)
        self.assertIn(
            "WlrLayershell.keyboardFocus: WlrKeyboardFocus.None", window
        )
        self.assertIn("mask: Region {\n            }", window)

    def test_position_preview_uses_a_numeric_duration(self) -> None:
        source = (
            REPOSITORY / "shell/modules/OsdController.qml"
        ).read_text(encoding="utf-8")

        self.assertIn('"󰍹", "info", 1400);', source)
        self.assertNotIn('"󰍹", "info", "1400");', source)

    def test_osd_separates_control_ipc_and_surface(self) -> None:
        modules = REPOSITORY / "shell/modules"
        root = (modules / "Osd.qml").read_text(encoding="utf-8")
        controller = (modules / "OsdController.qml").read_text(encoding="utf-8")
        ipc = (modules / "OsdIpc.qml").read_text(encoding="utf-8")
        surface = (modules / "OsdSurface.qml").read_text(encoding="utf-8")

        self.assertIn("OsdController {", root)
        self.assertIn("OsdIpc {", root)
        self.assertIn("OsdSurface {", root)
        self.assertNotIn("Process {", root)
        self.assertNotIn("PanelWindow {", root)
        self.assertIn("watch-audio.sh", controller)
        self.assertIn("watch-keyboard-backlight.sh", controller)
        self.assertIn("function showNotice(", controller)
        self.assertIn('target: "osd"', ipc)
        for command in (
            "volume",
            "brightness",
            "mic",
            "keyboard",
            "fan",
            "blueLight",
            "gpu",
            "caps",
            "camera",
            "touchpad",
            "notice",
        ):
            with self.subTest(command=command):
                self.assertIn(f"function {command}(", ipc)
        self.assertIn("Variants {", surface)


if __name__ == "__main__":
    unittest.main()
