from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import sys


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.browser_targets import BROWSER_TARGETS, detect_browser_target  # noqa: E402


class BrowserDetectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.apps = self.root / "applications"
        self.apps.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def add_binary(self, name: str, executable: bool = True) -> Path:
        path = self.root / name
        path.write_text("#!/bin/sh\n", encoding="utf-8")
        path.chmod(0o755 if executable else 0o644)
        return path

    def detect(self, paths: dict[str, Path | None], target: str = "helium") -> dict:
        return detect_browser_target(
            target,
            which=lambda name: str(paths.get(name)) if paths.get(name) else None,
            desktop_dirs=(self.apps,),
        )

    def test_browser_registry_keeps_helium_and_chromium_separate(self) -> None:
        self.assertEqual(("helium", "chromium"), tuple(target.id for target in BROWSER_TARGETS))
        self.assertEqual(("helium/manifest.json",), BROWSER_TARGETS[0].generated_files)
        self.assertEqual(("chromium/manifest.json",), BROWSER_TARGETS[1].generated_files)

    def test_executable_probe_reports_the_matching_install(self) -> None:
        binary = self.add_binary("helium-browser")
        result = self.detect({"helium-browser": binary, "helium": None})
        self.assertTrue(result["available"])
        self.assertEqual("executable", result["probe"]["kind"])
        self.assertEqual(str(binary), result["executable"])

    def test_absent_browser_is_hidden(self) -> None:
        result = self.detect({"helium-browser": None, "helium": None})
        self.assertFalse(result["available"])
        self.assertEqual("Helium is not installed", result["reason"])

    def test_stale_desktop_entry_does_not_count_as_installed(self) -> None:
        (self.apps / "helium.desktop").write_text("[Desktop Entry]\nExec=helium-browser %U\n", encoding="utf-8")
        result = self.detect({"helium-browser": None, "helium": None})
        self.assertFalse(result["available"])
        self.assertIn("stale", result["reason"])

    def test_non_executable_binary_is_rejected(self) -> None:
        binary = self.add_binary("helium-browser", executable=False)
        result = self.detect({"helium-browser": binary, "helium": None})
        self.assertFalse(result["available"])
        self.assertIn("not executable", result["reason"])

    def test_two_different_binary_probes_fail_closed_as_ambiguous(self) -> None:
        first = self.add_binary("helium-browser")
        second = self.add_binary("helium")
        result = self.detect({"helium-browser": first, "helium": second})
        self.assertFalse(result["available"])
        self.assertIn("ambiguous", result["reason"])
        self.assertEqual(2, len(result["matches"]))

    def test_blox_launcher_desktop_entry_cannot_fake_helium(self) -> None:
        launcher = self.add_binary("blox-helium-browser")
        (self.apps / "helium-browser.desktop").write_text(f"[Desktop Entry]\nExec={launcher} %U\n", encoding="utf-8")
        result = self.detect({"helium-browser": None, "helium": None})
        self.assertFalse(result["available"])
        self.assertEqual("Helium is not installed", result["reason"])

    def test_chromium_probe_reports_its_own_target_and_path(self) -> None:
        binary = self.add_binary("chromium")
        result = self.detect({"chromium": binary, "chromium-browser": None}, target="chromium")
        self.assertTrue(result["available"])
        self.assertEqual("Chromium", result["label"])
        self.assertEqual(str(binary), result["executable"])

    def test_chromium_stale_desktop_entry_uses_a_chromium_reason(self) -> None:
        (self.apps / "chromium.desktop").write_text("[Desktop Entry]\nExec=chromium %U\n", encoding="utf-8")
        result = self.detect({"chromium": None, "chromium-browser": None}, target="chromium")
        self.assertFalse(result["available"])
        self.assertIn("Chromium", result["reason"])


if __name__ == "__main__":
    unittest.main()
