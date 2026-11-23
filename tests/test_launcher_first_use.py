"""Exercise real launcher trees with process-free Qt Quick window adapters."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = "/usr/lib/qt6/bin/qmltestrunner" if Path("/usr/lib/qt6/bin/qmltestrunner").exists() else None


@unittest.skipUnless(RUNNER, "qmltestrunner is required")
class LauncherFirstUseTests(unittest.TestCase):
    def test_first_use_routes_and_retention(self):
        with tempfile.TemporaryDirectory(prefix="blox-launcher-first-use-") as directory:
            fixture = Path(directory)
            modules = fixture / "modules"
            modules.mkdir()
            for source in (ROOT / "shell/modules").iterdir():
                if source.is_file():
                    (modules / source.name).symlink_to(source)
            for name in ("shared", "assets"):
                (fixture / name).symlink_to(ROOT / "shell" / name)

            # Expose existing ids only in the private copy. Production keeps its
            # public API unchanged and uses these same component bodies.
            source = (modules / "Launcher.qml").read_text()
            source = source.replace("IpcHandler {", "IpcHandler {\n        id: fixtureIpc", 1)
            source = source.rsplit("}", 1)[0] + """
    function inspectFixture() {
        return {ipc: fixtureIpc, main: mainController, clipboard: clipboardController,
            emoji: emojiController, paste: pasteController, watcher: watcher, dmenu: dmenu,
            loaders: [mainSurfaceLoader, clipboardLoader, emojiLoader, quickApplyLoader]};
    }
}
"""
            (modules / "Launcher.qml").unlink()
            (modules / "Launcher.qml").write_text(source)

            # Existing Quickshell stubs do not provide layer-shell attachments.
            # Adapt only the native window declarations for a real host Window.
            surface = (modules / "LauncherMainSurface.qml").read_text()
            surface = "\n".join(line for line in surface.splitlines() if not any(
                token in line for token in ("exclusionMode:", "focusable:", "WlrLayershell.")))
            surface = surface.replace("PanelWindow {", "FloatingWindow {", 1)
            surface = surface.replace("""    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }""", "    width: 1000\n    height: 760")
            surface = surface.rsplit("}", 1)[0] + """
    function inspectFixture() {
        return {search: search, results: resultList, card: card};
    }
}
"""
            (modules / "LauncherMainSurface.qml").unlink()
            (modules / "LauncherMainSurface.qml").write_text(surface)

            imports = fixture / "imports"
            quickshell = imports / "Quickshell"
            shutil.copytree(ROOT / "tests/qml/imports/Quickshell", quickshell)
            singleton = quickshell / "Quickshell.qml"
            singleton.write_text(singleton.read_text().rsplit("}", 1)[0]
                                 + '    function iconPath(name, fallback) { return ""; }\n}\n')
            (quickshell / "DesktopEntries.qml").write_text('''pragma Singleton
import QtQuick
QtObject { property var applications: ({values: []}) }
''')
            with (quickshell / "qmldir").open("a") as output:
                output.write("singleton DesktopEntries 1.0 DesktopEntries.qml\n")
            test_source = (ROOT / "tests/fixtures/launcher-first-use/tst_LauncherFirstUse.qml").read_text()
            test_source = test_source.replace('"@SERVICES@"', '"' + (ROOT / "shell/services").as_uri() + '"')
            (fixture / "tst_LauncherFirstUse.qml").write_text(test_source)
            (fixture / "settings-owner-results.json").symlink_to(ROOT / "tests/fixtures/settings-owner-results.json")
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                       QT_QUICK_CONTROLS_STYLE="Basic", QML_DISABLE_DISK_CACHE="1",
                       QML_XHR_ALLOW_FILE_READ="1", QT_QPA_PLATFORMTHEME="generic", QML_IMPORT_PATH="")
            for name in ("WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
                env.pop(name, None)
            result = subprocess.run([RUNNER, "-import", str(ROOT / "tests/qml/imports"), "-import", str(imports),
                "-import", str(ROOT / "shell/native/qml"), "-input", str(fixture / "tst_LauncherFirstUse.qml")],
                env=env, capture_output=True, text=True, timeout=45)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            known_warnings = (
                "QObject::connect(QJSEngine, QtObject): invalid nullptr parameter",
                "Member palette of the object SettingsThemePreview_",
                "Member palette of the object SettingsThemeCard_",
            )
            for line in output.splitlines():
                if "QWARN" in line:
                    self.assertTrue(any(known in line for known in known_warnings), line)
            print(output, end="")


if __name__ == "__main__":
    unittest.main()
