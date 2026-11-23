"""Behavioural tests for Phase 6 multi-monitor identity and workspace app state."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPOSITORY / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


graphicsctl = load_module("graphicsctl_mm", "shell/scripts/graphicsctl.py")
workspaces = load_module("workspaces_status_mm", "shell/scripts/workspaces/status.py")


class OutputIdentityTests(unittest.TestCase):
    def test_edid_serial_identity_is_stable_across_connector_rename_and_redacted(self):
        dp1 = {
            "name": "DP-1", "make": "Dell Inc.", "model": "U2723QE",
            "serial": "ABC-987654", "description": "Dell U2723QE",
            "width": 3840, "height": 2160, "refreshRate": 60.0,
            "x": 0, "y": 0, "scale": 1.5, "transform": 0,
            "availableModes": ["3840x2160@60.00Hz", "2560x1440@60.00Hz"],
        }
        dp3 = dict(dp1, name="DP-3")
        first = graphicsctl.monitor_snapshot([dp1])["monitors"][0]
        second = graphicsctl.monitor_snapshot([dp3])["monitors"][0]
        self.assertEqual(first["identityKind"], "edid")
        self.assertEqual(first["logicalId"], second["logicalId"])
        self.assertNotIn("987654", first["logicalId"])
        self.assertFalse(first["volatile"])
        self.assertFalse(first["ambiguous"])
        self.assertEqual(len(first["modes"]), 2)

    def test_placeholder_serial_falls_back_to_description_and_headless_is_volatile(self):
        desc_only = {
            "name": "HDMI-A-1", "make": "LG", "model": "27GN800",
            "serial": "00000000", "description": "LG 27GN800",
            "width": 2560, "height": 1440, "refreshRate": 144.0,
            "x": 0, "y": 0, "scale": 1.0, "transform": 0,
        }
        headless = {
            "name": "HEADLESS-2", "make": "", "model": "", "serial": "",
            "description": "Headless output 2",
            "width": 1920, "height": 1080, "refreshRate": 60.0,
            "x": 2560, "y": 0, "scale": 1.25, "transform": 0,
        }
        snapshot = graphicsctl.monitor_snapshot([desc_only, headless])
        by_name = {m["name"]: m for m in snapshot["monitors"]}
        self.assertEqual(by_name["HDMI-A-1"]["identityKind"], "description")
        self.assertFalse(by_name["HDMI-A-1"]["serialPresent"])
        self.assertEqual(by_name["HEADLESS-2"]["identityKind"], "connector")
        self.assertEqual(by_name["HEADLESS-2"]["logicalId"], "connector:HEADLESS-2")
        self.assertTrue(by_name["HEADLESS-2"]["volatile"])

    def test_duplicate_identical_edid_serials_are_flagged_ambiguous(self):
        base = {
            "make": "Acme", "model": "Twin24", "serial": "SAME123",
            "description": "Acme Twin24", "width": 1920, "height": 1080,
            "refreshRate": 60.0, "x": 0, "y": 0, "scale": 1.0, "transform": 0,
        }
        snapshot = graphicsctl.monitor_snapshot([
            dict(base, name="DP-1"),
            dict(base, name="DP-2", x=1920),
        ])
        self.assertTrue(all(m["ambiguous"] for m in snapshot["monitors"]))


class WorkspaceAppsAndMonitorStateTests(unittest.TestCase):
    def test_desktop_entry_resolution_handles_wmclass_flatpak_and_hidden_entries(self):
        with tempfile.TemporaryDirectory(prefix="blox-desktop-entries-") as directory:
            apps_dir = Path(directory)
            (apps_dir / "org.mozilla.firefox.desktop").write_text(
                "[Desktop Entry]\nName=Firefox\nIcon=firefox\nStartupWMClass=firefox\n",
                encoding="utf-8",
            )
            (apps_dir / "com.discordapp.Discord.desktop").write_text(
                "[Desktop Entry]\nName=Discord\nIcon=discord\n",
                encoding="utf-8",
            )
            (apps_dir / "hidden.desktop").write_text(
                "[Desktop Entry]\nName=Hidden App\nIcon=secret\nHidden=true\nStartupWMClass=hidden\n",
                encoding="utf-8",
            )
            resolver = workspaces.DesktopEntryResolver([apps_dir])
            self.assertEqual(resolver.resolve("firefox")["iconName"], "firefox")
            self.assertEqual(resolver.resolve("com.discordapp.Discord")["name"], "Discord")
            self.assertEqual(resolver.resolve("discord")["iconName"], "discord")
            self.assertEqual(resolver.resolve("hidden")["iconName"], "")
            self.assertEqual(resolver.resolve("unknown-app")["name"], "unknown-app")

    def test_build_status_scopes_per_monitor_fullscreen_and_groups_apps(self):
        with tempfile.TemporaryDirectory(prefix="blox-ws-apps-") as directory:
            apps_dir = Path(directory)
            (apps_dir / "kitty.desktop").write_text(
                "[Desktop Entry]\nName=Kitty\nIcon=kitty\nStartupWMClass=kitty\n",
                encoding="utf-8",
            )
            resolver = workspaces.DesktopEntryResolver([apps_dir])
            payload = workspaces.build_status(
                active_value={"id": 1, "name": "1"},
                clients_value=[
                    {"class": "kitty", "title": "term 1", "address": "0x1", "workspace": {"id": 1}, "focusHistoryID": 1, "urgent": False},
                    {"class": "kitty", "title": "term 2", "address": "0x2", "workspace": {"id": 1}, "focusHistoryID": 2, "urgent": True},
                    {"class": "code", "title": "main.py", "address": "0x3", "workspace": {"id": 2}, "focusHistoryID": 3, "urgent": False},
                ],
                monitors_value=[
                    {"name": "eDP-1", "focused": True, "activeWorkspace": {"id": 1}},
                    {"name": "DP-1", "focused": False, "activeWorkspace": {"id": 2}},
                ],
                workspaces_value=[
                    {"id": 1, "monitor": "eDP-1", "hasfullscreen": False},
                    {"id": 2, "monitor": "DP-1", "hasfullscreen": True},
                ],
                resolver=resolver,
            )
            self.assertFalse(payload["monitors"]["eDP-1"]["hasFullscreen"])
            self.assertTrue(payload["monitors"]["DP-1"]["hasFullscreen"])
            by_id = {item["id"]: item for item in payload["main"]}
            self.assertEqual(by_id[1]["monitor"], "eDP-1")
            self.assertTrue(by_id[1]["activeOnMonitor"])
            self.assertEqual(by_id[1]["windowCount"], 2)
            self.assertEqual(len(by_id[1]["apps"]), 1)
            self.assertEqual(by_id[1]["apps"][0]["count"], 2)
            self.assertTrue(by_id[1]["apps"][0]["urgent"])
            self.assertEqual(by_id[1]["apps"][0]["iconName"], "kitty")
            self.assertEqual(by_id[2]["monitor"], "DP-1")
            self.assertTrue(by_id[2]["activeOnMonitor"])
            self.assertFalse(by_id[2]["active"])
            self.assertTrue(by_id[2]["hasFullscreen"])


if __name__ == "__main__":
    unittest.main()
