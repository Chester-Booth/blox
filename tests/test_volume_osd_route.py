"""The shared audio owner reaches OSD without a subprocess observer."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VolumeOsdRouteTests(unittest.TestCase):
    def test_same_owner_is_wired_through_bar_shell_and_osd(self):
        bar = (ROOT / "shell/modules/Bar.qml").read_text()
        shell = (ROOT / "shell/shell.qml").read_text()
        osd = (ROOT / "shell/modules/Osd.qml").read_text()
        self.assertIn("readonly property alias audioStatus: barContentController.audio", bar)
        self.assertIn("Osd {\n        id: osd\n\n        audioStatus: bar.audioStatus", shell)
        self.assertIn("property alias audioStatus: controller.audioStatus", osd)
        for source in [bar, shell, osd]:
            self.assertNotIn("AudioStatus {", source)
            self.assertNotIn("PipewireAudioProvider {", source)

    def test_volume_feedback_has_no_script_process_or_action_receipt_observer(self):
        source = (ROOT / "shell/modules/OsdController.qml").read_text()
        for forbidden in ["Process {", "pactl", "execDetached", "ipc.sh", "watch-audio.sh", ".action("]:
            self.assertNotIn(forbidden, source)
        self.assertIn("target: root.audioStatus", source)
        self.assertIn("const status = owner && owner.json", source)
        self.assertIn("const sink = owner && owner.sink", source)
        self.assertIn("KeyboardBacklightWatcher {", source)
        self.assertFalse((ROOT / "shell/scripts/osd/watch-audio.sh").exists())


if __name__ == "__main__":
    unittest.main()
