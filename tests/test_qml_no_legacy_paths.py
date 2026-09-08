"""QML must address helpers through the running shell, never the checkout."""

import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
SHELL = REPOSITORY / "shell"
FORBIDDEN = ".config/quickshell/blox"


class QmlPathHygieneTests(unittest.TestCase):
    def test_no_qml_references_the_legacy_checkout_path(self):
        offenders = []
        for qml in sorted(SHELL.rglob("*.qml")):
            if FORBIDDEN in qml.read_text(encoding="utf-8"):
                offenders.append(str(qml.relative_to(SHELL)))
        self.assertEqual([], offenders,
                         "hard-coded checkout paths break the installed product: "
                         + ", ".join(offenders))

    def test_theme_and_launcher_helpers_use_shelldir(self):
        controller = (SHELL / "modules/LauncherMainController.qml").read_text(encoding="utf-8")
        self.assertNotIn('Quickshell.env("HOME")', controller)
        self.assertIn('Quickshell.shellDir + "/scripts/theme/themectl.sh"', controller)

    def test_gpu_and_refresh_controls_have_no_legacy_command_fallback(self):
        qml = "\n".join(path.read_text(encoding="utf-8") for path in SHELL.rglob("*.qml"))
        for legacy in ("gpu/set-mode.sh", "gpu/on-safe.sh", "gpu/off-safe.sh", "01:00.0"):
            self.assertNotIn(legacy, qml)
        popout = (SHELL / "popouts/PerformancePopout.qml").read_text(encoding="utf-8")
        self.assertIn('"Refresh rate"', popout)
        self.assertIn('title: "GPU mode"', popout)

    def test_gpu_confirmation_uses_a_separate_window(self):
        popout = (SHELL / "popouts/PerformancePopout.qml").read_text(encoding="utf-8")
        window = (SHELL / "popouts/GpuModeConfirmationWindow.qml").read_text(encoding="utf-8")
        surfaces = (SHELL / "popouts/BarSystemSurfaces.qml").read_text(encoding="utf-8")
        self.assertNotIn('text: "Switch to Integrated?"', popout)
        self.assertIn("FloatingWindow {", window)
        self.assertIn('text: "Switch to " + root.requestedModeLabel + "?"', window)
        self.assertIn('root.switchingToIntegrated ? "HDMI will turn off.', window)
        self.assertIn("visible: root.activeClients.length > 0", window)
        self.assertIn('text: "Switch and log out"', window)
        self.assertIn("GpuModeConfirmationWindow {", surfaces)

    def test_every_gpu_mode_request_confirms_before_logout(self):
        provider = (SHELL / "services/GpuProvider.qml").read_text(encoding="utf-8")
        request_mode = provider.split("function requestMode(value)", 1)[1].split("function cancelModeRequest()", 1)[0]
        client_exit = provider.split("id: clientsProcess", 1)[1].split("id: actionProcess", 1)[0]
        self.assertNotIn("return root.setMode(mode, true)", request_mode)
        self.assertIn('if (mode !== "integrated")', request_mode)
        self.assertIn("root.confirmationRequired = true", request_mode)
        self.assertIn("root.confirmationRequired = true", client_exit)
        self.assertNotIn("root.setMode(mode, true)", client_exit)

    def test_gpu_mode_action_does_not_poll_the_controller_while_switching(self):
        provider = (SHELL / "services/GpuProvider.qml").read_text(encoding="utf-8")
        self.assertIn('["--logout"]', provider)
        self.assertNotIn("acceptanceMarker", provider)
        self.assertNotIn("pendingProbeProcess", provider)
        self.assertNotIn("pendingProbeDelay", provider)

    def test_power_logout_uses_the_current_hyprland_dispatcher(self):
        helper = (SHELL / "scripts/power/safe.sh").read_text(encoding="utf-8")
        self.assertIn("hyprctl dispatch 'hl.dsp.exit()'", helper)
        self.assertNotIn("hyprctl dispatch exit", helper)


if __name__ == "__main__":
    unittest.main()
