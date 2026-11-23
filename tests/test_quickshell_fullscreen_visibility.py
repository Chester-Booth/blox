"""Check the fullscreen binding against a real Quickshell window lifecycle."""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is required")
class QuickshellFullscreenVisibilityTests(unittest.TestCase):
    def test_fullscreen_window_maps_without_reentering_visibility(self):
        source = (ROOT / "shell/modules/DesktopWidgets.qml").read_text()
        surface = source.split("id: fullscreenSurface", 1)[1].split("Repeater {", 1)[0]
        bindings = {}
        for name in ("screen", "visible"):
            matches = re.findall(r"^\s*" + name + r": (.+)$", surface, re.MULTILINE)
            self.assertEqual(len(matches), 1)
            bindings[name] = matches[0]
        with tempfile.TemporaryDirectory(prefix="bqfs-", dir="/tmp") as temporary:
            root = Path(temporary)
            for name in ("home", "runtime", "config", "data", "state", "cache"):
                (root / name).mkdir(mode=0o700)
            qml = '''import QtQuick
import QtQuick.Window
import Quickshell
Scope {
    id: root
    property string fullscreenWidgetId: ""
    property string fullscreenOutputName: ""
    FloatingWindow {
        id: outputSurface
        screen: Quickshell.screens[0]
        implicitWidth: 80; implicitHeight: 60
        visible: true
        FloatingWindow {
            id: fullscreenSurface
            screen: SCREEN_BINDING
            implicitWidth: 80; implicitHeight: 60
            visible: VISIBLE_BINDING
        }
    }
    Timer {
        property bool entered: false
        interval: 100; running: true; repeat: true
        onTriggered: {
            if (!entered) {
                root.fullscreenOutputName = outputSurface.screen.name;
                root.fullscreenWidgetId = "selected";
                entered = true;
                return;
            }
            if (fullscreenSurface.visible && fullscreenSurface.contentItem.Window.window
                    && fullscreenSurface.contentItem.Window.window.visible)
                console.log("FULLSCREEN_BACKING_WINDOW_VISIBLE");
            Qt.quit();
        }
    }
}
'''.replace("SCREEN_BINDING", bindings["screen"]).replace("VISIBLE_BINDING", bindings["visible"])
            config = root / "shell.qml"
            config.write_text(qml)
            environment = {
                "PATH": os.defpath, "LANG": "C.UTF-8", "HOME": str(root / "home"),
                "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software",
                "QT_QPA_PLATFORMTHEME": "generic", "QS_DISABLE_CRASH_HANDLER": "1",
                "QML_DISABLE_DISK_CACHE": "1",
            }
            for name in ("runtime", "config", "data", "state", "cache"):
                environment["XDG_" + name.upper() + ("_DIR" if name == "runtime" else "_HOME")] = str(root / name)
            result = subprocess.run(
                ["quickshell", "--no-duplicate", "--no-color", "--path", str(config)],
                cwd=root, env=environment, capture_output=True, text=True, timeout=5)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("FULLSCREEN_BACKING_WINDOW_VISIBLE", output)
            self.assertNotIn("Binding loop detected", output)


if __name__ == "__main__":
    unittest.main()
