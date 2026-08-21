from __future__ import annotations

import copy
import hashlib
import json
import stat
import sys
import tempfile
import unittest
import zipfile
from collections.abc import Callable
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme import cli, portability
from blox_theme.core import CheckResult, load_theme


class PortabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.library = self.root / "library"
        self.theme_path, source = load_theme("catppuccin-mocha")
        self.theme = copy.deepcopy(source)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def export(self, name: str = "theme.blox-theme", include_wallpaper: bool = False) -> Path:
        output = self.root / name
        portability.export_bundle(self.theme, output, include_wallpaper=include_wallpaper, source_path=self.theme_path)
        return output

    def rewrite_archive(self, source: Path, destination: Path, change: Callable[[list], None]) -> None:
        with zipfile.ZipFile(source) as archive:
            members = [(info, archive.read(info.filename)) for info in archive.infolist()]
        change(members)
        with zipfile.ZipFile(destination, "w") as archive:
            for info, data in members:
                archive.writestr(info, data)

    def test_export_is_deterministic_and_loose_bundle_round_trip_preserves_theme(self) -> None:
        first = self.export("first.blox-theme")
        second = self.export("second.blox-theme")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(["manifest.json", "dependencies.json", "preview.svg", "theme.json"], archive.namelist())
            self.assertTrue(archive.read("preview.svg").startswith(b"<svg "))
            manifest = json.loads(archive.read("manifest.json"))
            for name, record in manifest["files"].items():
                data = archive.read(name)
                self.assertEqual(len(data), record["size"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])

        data, _ = portability.import_theme(first, self.library)
        imported = json.loads(Path(data["path"]).read_text(encoding="utf-8"))
        self.assertEqual(self.theme, imported)
        self.assertFalse(data["applied"])
        self.assertFalse(data["wallpaper_imported"])

    def test_wallpaper_bundle_imports_asset_and_rewrites_only_its_path(self) -> None:
        wallpaper = self.root / "wall paper.PNG"
        wallpaper.write_bytes(b"portable wallpaper")
        self.theme["id"] = "portable-wallpaper"
        self.theme["wallpaper"]["path"] = str(wallpaper)
        bundle = self.export(include_wallpaper=True)

        data, _ = portability.import_theme(bundle, self.library)
        imported = json.loads(Path(data["path"]).read_text(encoding="utf-8"))
        imported_wallpaper = Path(imported["wallpaper"]["path"])
        expected = copy.deepcopy(self.theme)
        expected["wallpaper"]["path"] = str(imported_wallpaper)
        self.assertEqual(expected, imported)
        self.assertEqual(b"portable wallpaper", imported_wallpaper.read_bytes())
        self.assertTrue(data["wallpaper_imported"])

    def test_builtin_wallpaper_bundle_keeps_the_source_reference_portable(self) -> None:
        self.theme["id"] = "repository-wallpaper"
        bundle = self.export(include_wallpaper=True)

        with zipfile.ZipFile(bundle) as archive:
            exported = json.loads(archive.read("theme.json"))
            self.assertEqual("wallpapers/showcase/catppuccin-mocha.webp", exported["wallpaper"]["path"])

        data, _ = portability.import_theme(bundle, self.library)
        imported = json.loads(Path(data["path"]).read_text(encoding="utf-8"))
        imported_wallpaper = Path(imported["wallpaper"]["path"])
        self.assertTrue(imported_wallpaper.is_file())
        self.assertEqual((THEMES / "wallpapers/showcase/catppuccin-mocha.webp").read_bytes(), imported_wallpaper.read_bytes())

    def test_import_cli_never_applies_and_reports_missing_dependencies_as_warnings(self) -> None:
        source = self.root / "loose.json"
        theme = copy.deepcopy(self.theme)
        theme.update(id="missing-dependencies", name="Missing Dependencies")
        source.write_text(json.dumps(theme), encoding="utf-8")
        missing = CheckResult(errors=["GTK base theme is not installed: Missing"], warnings=["font 'A' resolves to 'B'"])
        with (
            mock.patch("blox_theme.cli.themes_dir", return_value=self.library),
            mock.patch("blox_theme.cli.user_theme_library", return_value=self.library),
            mock.patch("blox_theme.portability.dependency_checks", return_value=missing),
            mock.patch("blox_theme.cli.apply_theme") as apply_theme,
        ):
            result, code = cli.run(cli.parser().parse_args(("import", str(source), "--json")))
        self.assertEqual(0, code, result)
        self.assertFalse(result["data"]["applied"])
        self.assertTrue(any("missing dependency" in warning for warning in result["warnings"]))
        apply_theme.assert_not_called()

    def test_import_cli_uses_the_xdg_data_library(self) -> None:
        source = self.root / "xdg-theme.json"
        theme = copy.deepcopy(self.theme)
        theme["id"] = "xdg-theme"
        source.write_text(json.dumps(theme), encoding="utf-8")
        data_home = self.root / "data"

        with mock.patch.dict("os.environ", {"XDG_DATA_HOME": str(data_home)}):
            result, code = cli.run(cli.parser().parse_args(("import", str(source), "--json")))
            listed, list_code = cli.run(cli.parser().parse_args(("list", "--json")))

        expected = data_home / "blox/themes/xdg-theme.json"
        self.assertEqual(0, code, result)
        self.assertEqual(0, list_code, listed)
        self.assertIn("xdg-theme", {entry["id"] for entry in listed["data"]})
        self.assertEqual(str(expected), result["data"]["path"])
        self.assertTrue(expected.is_file())

    def test_unsafe_paths_links_duplicates_and_digest_mismatches_are_rejected_without_writes(self) -> None:
        valid = self.export()
        cases: dict[str, Callable[[list], None]] = {
            "traversal": lambda members: members.append((zipfile.ZipInfo("../escape"), b"bad")),
            "duplicate": lambda members: members.append((members[-1][0], members[-1][1])),
            "digest": lambda members: members.__setitem__(
                next(index for index, (info, _) in enumerate(members) if info.filename == "theme.json"),
                (next(info for info, _ in members if info.filename == "theme.json"), b"{}\n"),
            ),
        }
        for name, mutation in cases.items():
            with self.subTest(name=name):
                candidate = self.root / f"{name}.blox-theme"
                self.rewrite_archive(valid, candidate, mutation)
                with self.assertRaises(portability.PortabilityFailure):
                    portability.import_theme(candidate, self.library)
                self.assertFalse((self.library / "themes").exists())
                self.assertFalse((self.root / "escape").exists())

        link_bundle = self.root / "link.blox-theme"
        info = zipfile.ZipInfo("manifest.json")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(link_bundle, "w") as archive:
            archive.writestr(info, b"target")
        with self.assertRaisesRegex(portability.PortabilityFailure, "regular file"):
            portability.import_theme(link_bundle, self.library)
        self.assertFalse((self.library / "themes").exists())

    def test_limits_and_unsupported_schema_fail_before_library_mutation(self) -> None:
        future = copy.deepcopy(self.theme)
        future["schema_version"] = 2
        loose = self.root / "future.json"
        loose.write_text(json.dumps(future), encoding="utf-8")
        with self.assertRaisesRegex(portability.PortabilityFailure, "newer than supported"):
            portability.import_theme(loose, self.library)
        self.assertFalse(self.library.exists())

        oversized = self.root / "oversized.json"
        oversized.write_bytes(b"{}" + b" " * 20)
        with mock.patch.object(portability, "MAX_LOOSE_JSON_BYTES", 10):
            with self.assertRaisesRegex(portability.PortabilityFailure, "limit"):
                portability.import_theme(oversized, self.library)
        self.assertFalse(self.library.exists())

    def test_migration_hook_is_explicit_and_then_strictly_validated(self) -> None:
        old = copy.deepcopy(self.theme)
        old["schema_version"] = 0

        def migrate(value: dict) -> dict:
            migrated = copy.deepcopy(value)
            migrated["schema_version"] = 1
            return migrated

        with mock.patch.dict(portability.THEME_MIGRATIONS, {0: migrate}, clear=True):
            migrated, warnings = portability.migrate_theme(old)
        self.assertEqual(self.theme, migrated)
        self.assertEqual(["migrated theme schema from version 0 to 1"], warnings)

    def test_existing_theme_or_export_is_never_overwritten(self) -> None:
        output = self.root / "existing.blox-theme"
        output.write_bytes(b"keep")
        with self.assertRaises(portability.PortabilityFailure):
            portability.export_bundle(self.theme, output)
        self.assertEqual(b"keep", output.read_bytes())

        (self.library / "themes").mkdir(parents=True)
        existing = self.library / "themes/catppuccin-mocha.json"
        existing.write_text("keep", encoding="utf-8")
        source = self.root / "source.json"
        source.write_text(json.dumps(self.theme), encoding="utf-8")
        with self.assertRaises(portability.PortabilityFailure):
            portability.import_theme(source, self.library)
        self.assertEqual("keep", existing.read_text(encoding="utf-8"))

    def test_import_rejects_source_links_and_cleans_partial_wallpaper_writes(self) -> None:
        source = self.root / "source.json"
        source.write_text(json.dumps(self.theme), encoding="utf-8")
        link = self.root / "source-link.json"
        link.symlink_to(source)
        with self.assertRaisesRegex(portability.PortabilityFailure, "regular file"):
            portability.import_theme(link, self.library)

        wallpaper = self.root / "wallpaper.png"
        wallpaper.write_bytes(b"wallpaper")
        self.theme["id"] = "partial-import"
        self.theme["wallpaper"]["path"] = str(wallpaper)
        bundle = self.export(include_wallpaper=True)
        with mock.patch("blox_theme.portability.save_theme_source", side_effect=portability.GeneratorFailure("stop")):
            with self.assertRaises(portability.GeneratorFailure):
                portability.import_theme(bundle, self.library)
        self.assertFalse((self.library / "wallpapers/partial-import").exists())
        self.assertFalse((self.library / "themes/partial-import.json").exists())


if __name__ == "__main__":
    unittest.main()
