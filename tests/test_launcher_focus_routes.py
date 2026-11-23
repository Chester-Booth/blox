import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class LauncherFocusRouteTests(unittest.TestCase):
    def test_main_escape_uses_explicit_return_route(self):
        surface = (ROOT / "shell/modules/LauncherMainSurface.qml").read_text(encoding="utf-8")
        launcher = (ROOT / "shell/modules/Launcher.qml").read_text(encoding="utf-8")

        self.assertIn("controller.dismissRequested();", surface)
        self.assertIn("onDismissRequested: mainFocusReturn.dismiss()", launcher)
        self.assertIn("onCloseRequested: root.close()", launcher)

    def test_dmenu_cancel_and_selection_return_to_the_captured_app(self):
        launcher = (ROOT / "shell/modules/Launcher.qml").read_text(encoding="utf-8")
        surface = (ROOT / "shell/modules/LauncherMainSurface.qml").read_text(encoding="utf-8")

        self.assertIn("if (root.activeSurface === \"idle\")\n                pasteController.captureTarget();", launcher)
        self.assertIn("mainFocusReturn.selectDmenu();", launcher)
        self.assertIn("controller.dismissRequested();", surface)

    def test_normal_app_launch_keeps_generic_close_without_focus_restore(self):
        controller = (ROOT / "shell/modules/LauncherMainController.qml").read_text(encoding="utf-8")
        launcher = (ROOT / "shell/modules/Launcher.qml").read_text(encoding="utf-8")
        activation = controller.split("function activateResult(index)", 1)[1].split("function activate()", 1)[0]

        self.assertIn('enqueueLaunch(result.entry, "application")', activation)
        self.assertIn("closeRequested();", activation)
        self.assertNotIn("dismissRequested()", activation)
        self.assertIn("onCloseRequested: root.close()", launcher)


if __name__ == "__main__":
    unittest.main()
