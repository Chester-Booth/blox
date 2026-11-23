"""Check the actual Settings metadata transport without loading the Settings shell."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is required for metadata transport verification")
class WidgetMetadataBootstrapTests(unittest.TestCase):
    def test_closed_open_reopen_and_parse_error(self):
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="blox-widget-meta-") as temporary:
            directory = Path(temporary)
            shared = directory / "shared"
            shared.mkdir()
            (shared / "qmldir").write_text("singleton Theme 1.0 Theme.qml\n")
            (shared / "Theme.qml").write_text("pragma Singleton\nimport QtQml\nQtObject { property var widgetRegistry: ({}); property bool widgetRegistryLoaded: false }")
            shutil.copyfile(ROOT / "shell/modules/SettingsWidgetMetadataLoader.qml", directory / "SettingsWidgetMetadataLoader.qml")
            # Exercise the real SettingsWidgetMetadataLoader component directly.
            (directory / "shell.qml").write_text("""import QtQuick
import Quickshell
import Quickshell.Io
import qs.shared
Scope {
    id: root
    property bool windowOpen: false
    property int scans: 0
    property int completions: 0
    property int stage: 0
    property int ticks: 0
    readonly property string widgetSourceRoot: Quickshell.env("BLOX_WIDGETS_ROOT")
    property alias widgetCatalogue: widgetMetadata.widgetCatalogue
    property alias widgetSchema: widgetMetadata.widgetSchema
    property alias widgetCatalogueError: widgetMetadata.widgetCatalogueError
    readonly property string widgetMetadataError: widgetMetadata.widgetMetadataError
    function loadWidgetMetadata(kind, text) { widgetMetadata.loadMetadata(kind, text); }
    SettingsWidgetMetadataLoader {
        id: widgetMetadata
        active: root.windowOpen
        widgetSourceRoot: root.widgetSourceRoot
    }
    Connections {
        target: widgetMetadata.registryProcess
        function onStarted() { root.scans++; }
        function onExited() { root.completions++; }
    }
    Timer {
        interval: 20; repeat: true; running: true
        onTriggered: {
            if (++root.ticks > 200) { console.log("METADATA-FAILED timeout " + root.widgetMetadataError); Qt.quit(); return; }
            if (root.stage === 0) {
                if (root.scans !== 0) { console.log("METADATA-FAILED closed scan"); Qt.quit(); return; }
                root.windowOpen = true;
                root.stage = 1;
            } else if (root.stage === 1 && root.completions === 1 && root.widgetCatalogue && root.widgetSchema) {
                if (root.widgetMetadataError || !Theme.widgetRegistryLoaded || root.scans !== 1) {
                    console.log("METADATA-FAILED first open " + root.widgetMetadataError); Qt.quit(); return;
                }
                root.windowOpen = false;
                root.stage = 2;
            } else if (root.stage === 2) {
                root.windowOpen = true;
                root.stage = 3;
            } else if (root.stage === 3 && root.completions === 2 && root.widgetCatalogue && root.widgetSchema) {
                if (root.widgetMetadataError || root.scans !== 2) { console.log("METADATA-FAILED reopen"); Qt.quit(); return; }
                root.loadWidgetMetadata("catalogue", "{broken");
                if (root.widgetCatalogue !== null || !root.widgetCatalogueError) { console.log("METADATA-FAILED parse error"); Qt.quit(); return; }
                console.log("METADATA-PASSED exactly-two-scans"); Qt.quit();
            }
        }
    }
}
""")
            environment = dict(os.environ)
            for name in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "QT_QPA_PLATFORMTHEME", "QT_STYLE_OVERRIDE"):
                environment.pop(name, None)
            for name in ("XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
                path = directory / name
                path.mkdir(mode=0o700)
                environment[name] = str(path)
            environment.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", BLOX_WIDGETS_ROOT=str(ROOT / "widgets"))
            result = subprocess.run(["quickshell", "--path", str(directory)], env=environment,
                                    capture_output=True, text=True, timeout=8)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("METADATA-PASSED exactly-two-scans", output)
            self.assertNotIn("METADATA-FAILED", output)
            self.assertNotIn("TypeError", output)


if __name__ == "__main__":
    unittest.main()
