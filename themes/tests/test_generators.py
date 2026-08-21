from __future__ import annotations

import copy
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
FIXTURES = THEMES / "tests/fixtures"
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import derive_ansi, load_theme, schema_errors, validate_theme
from blox_theme.generators import GeneratorFailure, contrast_report, generate_theme, map_matugen, map_pywal, save_theme_source


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class MappingTests(unittest.TestCase):
    def test_matugen_mapping_is_explicit_and_valid(self) -> None:
        colours = map_matugen(fixture("matugen-output.json"), "dark")
        self.assertEqual("#101114", colours["background"])
        self.assertEqual("#b9c3ff", colours["accent"])
        self.assertEqual("#172c60", colours["selection_foreground"])
        self.assertTrue(all(item["ok"] for item in contrast_report(colours)))

    def test_pywal_mapping_prefers_contrasting_bright_roles(self) -> None:
        colours = map_pywal(fixture("pywal-output.json"), "dark")
        self.assertEqual("#b9c3ff", colours["accent"])
        self.assertEqual("#ffb4ab", colours["danger"])
        self.assertEqual("#101114", colours["selection_foreground"])
        self.assertTrue(all(item["ok"] for item in contrast_report(colours)))

    def test_malformed_backend_output_is_isolated(self) -> None:
        with self.assertRaisesRegex(GeneratorFailure, "missing"):
            map_matugen({"colors": {}}, "dark")
        broken = fixture("pywal-output.json")
        broken["colors"]["color12"] = "rgb(1, 2, 3)"
        with self.assertRaisesRegex(GeneratorFailure, "color12"):
            map_pywal(broken, "dark")

    def test_contrast_report_exposes_failures(self) -> None:
        colours = map_matugen(fixture("matugen-output.json"), "dark")
        colours["muted"] = colours["background"]
        failed = [item for item in contrast_report(colours) if not item["ok"]]
        self.assertEqual([("muted", "background")], [(item["foreground"], item["background"]) for item in failed])


class AdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.wallpaper = self.root / "My Wallpaper.png"
        self.wallpaper.write_bytes(b"stable wallpaper bytes")
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def executable(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def environment(self) -> mock._patch_dict:
        return mock.patch.dict(os.environ, {"PATH": f"{self.bin}:{os.environ['PATH']}"})

    def test_matugen_adapter_is_deterministic_and_sandboxed(self) -> None:
        payload = json.dumps(fixture("matugen-output.json"))
        self.executable("matugen", f'''import json, os, sys
if "--version" in sys.argv:
    print("matugen 4.1.0")
else:
    assert "--dry-run" in sys.argv and "--source-color-index" in sys.argv
    assert os.environ["HOME"].startswith("/tmp/themectl-matugen-")
    print({payload!r})
''')
        with self.environment():
            first, report = generate_theme(self.wallpaper)
            second, _ = generate_theme(self.wallpaper)
        self.assertEqual(first, second)
        self.assertTrue(all(item["ok"] for item in report))
        self.assertEqual("4.1.0", first["generator"]["version"])
        self.assertEqual(1, first["generator"]["mapping_version"])
        self.assertEqual("my-wallpaper-matugen", first["id"])
        self.assertEqual(first["colours"]["danger"], derive_ansi(first)["color1"])
        self.assertEqual(first["colours"]["info"], derive_ansi(first)["color4"])
        self.assertEqual([], validate_theme(first, check_dependencies=False).errors)

    def test_pywal_adapter_reads_only_isolated_cache(self) -> None:
        payload = json.dumps(fixture("pywal-output.json"))
        self.executable("wal", f'''import json, os, pathlib, sys
if "-v" in sys.argv:
    print("wal 3.3.0")
else:
    assert all(flag in sys.argv for flag in ("-n", "-s", "-t", "-e", "-q"))
    output = pathlib.Path(os.environ["HOME"]) / ".cache/wal/colors.json"
    output.parent.mkdir(parents=True)
    output.write_text({payload!r})
''')
        with self.environment():
            theme, report = generate_theme(self.wallpaper, backend="pywal", saturation=0.4)
        self.assertTrue(all(item["ok"] for item in report))
        self.assertEqual({"mode": "dark", "saturation": 0.4}, theme["generator"]["options"])
        self.assertEqual([], validate_theme(theme, check_dependencies=False).errors)

    def test_backend_errors_do_not_create_theme_or_live_cache(self) -> None:
        self.executable("matugen", '''import sys
if "--version" in sys.argv: print("matugen 4.1.0")
else: print("bad image", file=sys.stderr); raise SystemExit(9)
''')
        live_cache = self.root / "live-cache"
        with self.environment(), mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(live_cache)}):
            with self.assertRaisesRegex(GeneratorFailure, "bad image"):
                generate_theme(self.wallpaper)
        self.assertFalse(live_cache.exists())

    def test_input_boundaries_and_disabled_wallust(self) -> None:
        with self.assertRaisesRegex(GeneratorFailure, "disabled"):
            generate_theme(self.wallpaper, backend="wallust")
        with self.assertRaisesRegex(FileNotFoundError, "does not exist"):
            generate_theme(self.root / "missing.png")
        with self.assertRaisesRegex(GeneratorFailure, "regular file"):
            generate_theme(self.root)
        with self.assertRaisesRegex(GeneratorFailure, "not valid with pywal"):
            generate_theme(self.wallpaper, backend="pywal", contrast=0.5)
        with self.assertRaisesRegex(GeneratorFailure, "between 0 and 1"):
            generate_theme(self.wallpaper, backend="pywal", saturation=2)
        self.executable("matugen", 'import sys\nprint("matugen 4.1.0")\n')
        with self.environment():
            with self.assertRaisesRegex(GeneratorFailure, "between -1 and 1"):
                generate_theme(self.wallpaper, contrast=1.1)
            with self.assertRaisesRegex(GeneratorFailure, "source colour index"):
                generate_theme(self.wallpaper, source_colour_index=4)
            with self.assertRaisesRegex(GeneratorFailure, "only valid with the pywal"):
                generate_theme(self.wallpaper, saturation=0.5)
            with self.assertRaisesRegex(GeneratorFailure, "unsupported generator mode"):
                generate_theme(self.wallpaper, mode="sepia")


class SaveTests(unittest.TestCase):
    def test_save_is_canonical_atomic_and_refuses_overwrite(self) -> None:
        _, source = load_theme("catppuccin-mocha")
        theme = copy.deepcopy(source)
        theme["id"] = "generated-test"
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = save_theme_source(theme, directory)
            self.assertEqual(theme, json.loads(path.read_text(encoding="utf-8")))
            self.assertEqual(0o644, path.stat().st_mode & 0o777)
            self.assertEqual([], list(directory.glob(".*.json")))
            with self.assertRaisesRegex(GeneratorFailure, "already exists"):
                save_theme_source(theme, directory)
            self.assertEqual(theme, json.loads(path.read_text(encoding="utf-8")))

    def test_save_rejects_unsafe_id(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["id"] = "../escape"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(GeneratorFailure, "safe"):
                save_theme_source(theme, Path(temporary))

    def test_generator_schema_provenance_is_strict(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["generator"] = {
            "backend": "matugen", "version": "4.1.0", "mapping_version": 1,
            "options": {"mode": "dark", "scheme": "scheme-tonal-spot", "contrast": 0, "source_colour_index": 0},
            "wallpaper_sha256": "a" * 64,
        }
        self.assertEqual([], schema_errors(theme))
        theme["generator"]["options"]["unknown"] = True
        self.assertTrue(schema_errors(theme))

    def test_validation_allows_changed_source_wallpaper(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        with tempfile.TemporaryDirectory() as temporary:
            wallpaper = Path(temporary) / "wallpaper.png"
            wallpaper.write_bytes(b"changed")
            theme["wallpaper"]["path"] = str(wallpaper)
            theme["generator"] = {
                "backend": "pywal", "version": "3.3.0", "mapping_version": 1,
                "options": {"mode": "dark"}, "wallpaper_sha256": "0" * 64,
            }
            result = validate_theme(theme, check_dependencies=True)
        self.assertFalse(any("digest" in error for error in result.errors))


class CliTests(unittest.TestCase):
    def test_save_rejects_invalid_json_without_writing(self) -> None:
        completed = subprocess.run(
            [str(THEMES / "bin/themectl"), "save", "{bad", "--json"],
            cwd=REPOSITORY, capture_output=True, text=True, check=False,
        )
        self.assertEqual(3, completed.returncode)
        self.assertFalse(json.loads(completed.stdout)["ok"])

    def test_generate_reports_missing_backend_as_dependency(self) -> None:
        environment = os.environ.copy()
        environment["PATH"] = "/nonexistent"
        completed = subprocess.run(
            [sys.executable, str(THEMES / "bin/themectl"), "generate", str(FIXTURES / "pywal-output.json"), "--json"],
            cwd=REPOSITORY, env=environment, capture_output=True, text=True, check=False,
        )
        self.assertEqual(4, completed.returncode)
