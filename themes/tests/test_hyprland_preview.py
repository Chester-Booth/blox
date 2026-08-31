from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
sys.path.insert(0, str(THEMES / "lib"))

SCRIPT = REPOSITORY / "shell/scripts/theme/hyprland_preview.py"
SPEC = importlib.util.spec_from_file_location("blox_hyprland_preview", SCRIPT)
assert SPEC and SPEC.loader
PREVIEW = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PREVIEW
SPEC.loader.exec_module(PREVIEW)

from blox_theme.core import load_theme  # noqa: E402


class HyprlandPreviewTests(unittest.TestCase):
    def setUp(self) -> None:
        _, self.theme = load_theme("catppuccin-mocha")
        self.theme["targets"] = {key: key == "hyprland" for key in self.theme["targets"]}

    def test_gradient_option_is_converted_to_keyword_syntax(self) -> None:
        self.assertEqual(
            "rgba(89b4faee) rgba(a6e3a1ee) 45",
            PREVIEW.gradient_keyword("ee89b4fa eea6e3a1 45deg"),
        )

    def test_lua_config_preserves_gap_edges_and_border_values(self) -> None:
        values = {
            "general:border_size": "3",
            "general:gaps_in": "4 5 6 7",
            "general:gaps_out": "8 9 10 11",
            "general:col.active_border": "rgba(89b4faee)",
            "general:col.inactive_border": "rgba(3b3c4aaa) 0",
            "decoration:rounding": "7",
            "decoration:inactive_opacity": "0.62",
            "decoration:shadow:color": "rgba(242424ee) 0",
        }
        expression = PREVIEW.lua_config(values)
        self.assertIn("hl.config", expression)
        self.assertIn("border_size = 3", expression)
        self.assertIn("gaps_in = { top = 4, right = 5, bottom = 6, left = 7 }", expression)
        self.assertIn("gaps_out = { top = 8, right = 9, bottom = 10, left = 11 }", expression)
        self.assertIn('active_border = "rgba(89b4faee)"', expression)
        self.assertIn('inactive_border = "rgba(3b3c4aaa)"', expression)

    def test_lua_provider_uses_eval_for_apply_and_restore(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "preview.json"
            calls: list[tuple[str, ...]] = []

            def fake_run(*arguments: str) -> subprocess.CompletedProcess[str]:
                calls.append(arguments)
                if arguments[:2] == ("status", "-j"):
                    return subprocess.CompletedProcess(arguments, 0, '{"configProvider":"lua"}', "")
                if arguments[0] == "eval":
                    return subprocess.CompletedProcess(arguments, 0, "ok\n", "")
                if arguments[:2] == ("getoption", "general:gaps_in"):
                    return subprocess.CompletedProcess(arguments, 0, '{"css":"0 0 0 0","set":true}', "")
                if arguments[:2] == ("getoption", "general:border_size"):
                    return subprocess.CompletedProcess(arguments, 0, '{"int":1,"set":true}', "")
                if arguments[:2] == ("getoption", "general:gaps_out"):
                    return subprocess.CompletedProcess(arguments, 0, '{"css":"0 0 0 0","set":true}', "")
                if arguments[:2] == ("getoption", "general:col.active_border"):
                    return subprocess.CompletedProcess(arguments, 0, '{"gradient":"ee89b4fa eea6e3a1 45deg","set":true}', "")
                if arguments[:2] == ("getoption", "general:col.inactive_border"):
                    return subprocess.CompletedProcess(arguments, 0, '{"gradient":"aa3b3c4a 0deg","set":true}', "")
                if arguments[:2] == ("getoption", "decoration:rounding"):
                    return subprocess.CompletedProcess(arguments, 0, '{"int":0,"set":true}', "")
                if arguments[:2] == ("getoption", "decoration:inactive_opacity"):
                    return subprocess.CompletedProcess(arguments, 0, '{"float":0.8,"set":true}', "")
                if arguments[:2] == ("getoption", "decoration:shadow:color"):
                    return subprocess.CompletedProcess(arguments, 0, '{"gradient":"ee242424 0deg","set":true}', "")
                return subprocess.CompletedProcess(arguments, 1, "", "unexpected command")

            with mock.patch.object(PREVIEW, "run_hyprctl", side_effect=fake_run), mock.patch.object(
                PREVIEW, "state_path", return_value=state
            ):
                PREVIEW.apply(self.theme)
                PREVIEW.restore()

            eval_calls = [call for call in calls if call[:1] == ("eval",)]
            self.assertEqual(2, len(eval_calls))
            self.assertTrue(eval_calls[0][1].startswith("hl.config({"))

    def test_preview_values_include_existing_and_new_hyprland_settings(self) -> None:
        self.theme["shape"].update(radius_scale=0.65, density_scale=1.5, window_gap=None)
        self.theme["hyprland"] = {"inactive_opacity": 0.62, "border_size": 7}
        values = PREVIEW.preview_values(self.theme)
        self.assertEqual("7", values["general:border_size"])
        self.assertEqual("15", values["general:gaps_in"])
        self.assertEqual("15", values["general:gaps_out"])
        self.assertEqual("8", values["decoration:rounding"])
        self.assertEqual("0.62", values["decoration:inactive_opacity"])
        self.assertEqual("rgba(89b4faee)", values["general:col.active_border"])

    def test_apply_snapshots_once_and_restore_removes_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "preview.json"
            calls: list[tuple[str, ...]] = []

            def fake_run(*arguments: str) -> subprocess.CompletedProcess[str]:
                calls.append(arguments)
                if arguments[:2] == ("getoption", "general:gaps_in"):
                    return subprocess.CompletedProcess(arguments, 0, '{"css":"0 0 0 0","set":true}', "")
                if arguments[:2] == ("getoption", "general:border_size"):
                    return subprocess.CompletedProcess(arguments, 0, '{"int":1,"set":true}', "")
                if arguments[:2] == ("getoption", "general:gaps_out"):
                    return subprocess.CompletedProcess(arguments, 0, '{"css":"0 0 0 0","set":true}', "")
                if arguments[:2] == ("getoption", "general:col.active_border"):
                    return subprocess.CompletedProcess(arguments, 0, '{"gradient":"ee89b4fa eea6e3a1 45deg","set":true}', "")
                if arguments[:2] == ("getoption", "general:col.inactive_border"):
                    return subprocess.CompletedProcess(arguments, 0, '{"gradient":"aa3b3c4a 0deg","set":true}', "")
                if arguments[:2] == ("getoption", "decoration:rounding"):
                    return subprocess.CompletedProcess(arguments, 0, '{"int":0,"set":true}', "")
                if arguments[:2] == ("getoption", "decoration:inactive_opacity"):
                    return subprocess.CompletedProcess(arguments, 0, '{"float":0.8,"set":true}', "")
                if arguments[:2] == ("getoption", "decoration:shadow:color"):
                    return subprocess.CompletedProcess(arguments, 0, '{"gradient":"ee242424 0deg","set":true}', "")
                return subprocess.CompletedProcess(arguments, 0, "ok\n", "")

            with mock.patch.object(PREVIEW, "run_hyprctl", side_effect=fake_run), mock.patch.object(
                PREVIEW, "state_path", return_value=state
            ):
                PREVIEW.apply(self.theme)
                self.assertTrue(state.is_file())
                self.assertEqual(1, sum(call[:1] == ("--batch",) for call in calls))

                PREVIEW.apply(self.theme)
                self.assertEqual(2, sum(call[:1] == ("--batch",) for call in calls))

                PREVIEW.restore()
                self.assertFalse(state.exists())
                self.assertEqual(3, sum(call[:1] == ("--batch",) for call in calls))

            saved = json.loads(state.read_text()) if state.exists() else None
            self.assertIsNone(saved)


if __name__ == "__main__":
    unittest.main()
