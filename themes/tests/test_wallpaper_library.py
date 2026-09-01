from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme import wallpapers
from blox_theme.core import load_theme


class WallpaperLibraryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package = self.root / "package"
        self.user = self.root / "user"
        (self.package / "wallpapers/showcase").mkdir(parents=True)
        (self.package / "wallpapers/builtin").mkdir(parents=True)
        (self.package / "builtin").mkdir(parents=True)
        (self.user / "themes").mkdir(parents=True)
        self.theme = copy.deepcopy(load_theme("catppuccin-mocha")[1])
        self.theme["id"] = "wallpaper-owner"
        self.theme["name"] = "Wallpaper Owner"
        self.patches = [
            mock.patch.object(wallpapers, "themes_dir", return_value=self.package),
            mock.patch.object(wallpapers, "builtin_themes_dir", return_value=self.package / "builtin"),
            mock.patch.object(wallpapers, "user_theme_library", return_value=self.user),
            mock.patch.object(
                wallpapers,
                "resolve_wallpaper_path",
                side_effect=lambda value, source=None: Path(value).expanduser() if Path(value).is_absolute() else self.package / value,
            ),
        ]
        for patcher in self.patches:
            patcher.start()

    def tearDown(self) -> None:
        for patcher in reversed(self.patches):
            patcher.stop()
        self.temporary.cleanup()

    @staticmethod
    def write_image(path: Path, marker: bytes) -> None:
        path.write_bytes(marker + b" wallpaper data")

    def test_lists_builtins_and_imports_each_digest_once(self) -> None:
        builtin = self.package / "wallpapers/showcase/blue.webp"
        self.write_image(builtin, b"RIFF0000WEBP")
        package_blank = self.package / "wallpapers/builtin/blank-light.png"
        self.write_image(package_blank, b"\x89PNG\r\n\x1a\nblank-light")
        source = self.root / "My wallpaper.PNG"
        self.write_image(source, b"\x89PNG\r\n\x1a\n")

        listed = wallpapers.list_wallpapers()
        self.assertEqual(["Blank Light", "Blue"], [entry["name"] for entry in listed])
        self.assertEqual(["Built in", "Built in"], [entry["kind"] for entry in listed])

        imported = wallpapers.import_wallpaper(source, "wallpaper-owner")
        self.assertTrue(imported["imported"])
        self.assertFalse(imported["duplicate"])
        self.assertTrue(Path(imported["path"]).is_file())
        self.assertEqual(source.read_bytes(), Path(imported["path"]).read_bytes())
        duplicate = wallpapers.import_wallpaper(source, "wallpaper-owner")
        self.assertFalse(duplicate["imported"])
        self.assertTrue(duplicate["duplicate"])
        self.assertEqual(imported["id"], duplicate["id"])
        self.assertEqual(1, len(list((self.user / "wallpapers").rglob("*.png"))))

    def test_removal_refuses_saved_theme_then_removes_managed_copy(self) -> None:
        source = self.root / "wallpaper.jpg"
        self.write_image(source, b"\xff\xd8\xff")
        imported = wallpapers.import_wallpaper(source, "wallpaper-owner")
        managed = Path(imported["path"])
        self.theme["wallpaper"]["path"] = str(managed)
        (self.user / "themes/wallpaper-owner.json").write_text(json.dumps(self.theme), encoding="utf-8")

        with self.assertRaisesRegex(wallpapers.WallpaperFailure, "saved theme"):
            wallpapers.remove_wallpaper(imported["id"])
        self.assertTrue(managed.is_file())

        (self.user / "themes/wallpaper-owner.json").unlink()
        removed = wallpapers.remove_wallpaper(imported["id"])
        self.assertTrue(removed["removed"])
        self.assertFalse(managed.exists())
        self.assertFalse((self.user / "wallpapers/wallpaper-owner").exists())

    def test_migrates_external_theme_wallpapers_to_removable_managed_imports(self) -> None:
        source = self.root / "Side Down Close.png"
        self.write_image(source, b"\x89PNG\r\n\x1a\n")
        theme = copy.deepcopy(self.theme)
        theme["id"] = "side-down-close"
        theme["name"] = "Side Down Close"
        theme["wallpaper"]["path"] = str(source)
        (self.user / "themes/side-down-close.json").write_text(json.dumps(theme), encoding="utf-8")
        second = copy.deepcopy(theme)
        second["id"] = "side-down-close-copy"
        (self.user / "themes/side-down-close-copy.json").write_text(json.dumps(second), encoding="utf-8")

        listed = wallpapers.migrate_theme_wallpapers()

        self.assertEqual(1, len(listed))
        self.assertEqual("Imported", listed[0]["kind"])
        self.assertEqual("Side Down Close", listed[0]["name"])
        self.assertTrue(listed[0]["removable"])
        managed = Path(listed[0]["path"])
        self.assertNotEqual(source, managed)
        self.assertTrue(managed.is_relative_to(self.user / "wallpapers"))
        self.assertEqual(source.read_bytes(), managed.read_bytes())
        self.assertEqual(str(managed), json.loads((self.user / "themes/side-down-close.json").read_text())["wallpaper"]["path"])
        self.assertEqual(str(managed), json.loads((self.user / "themes/side-down-close-copy.json").read_text())["wallpaper"]["path"])
        self.assertTrue(source.is_file())

    def test_package_blank_reference_is_not_migrated_as_a_user_import(self) -> None:
        package_blank = self.package / "wallpapers/builtin/blank-light.png"
        self.write_image(package_blank, b"\x89PNG\r\n\x1a\nblank-light")
        theme = copy.deepcopy(self.theme)
        theme["wallpaper"]["path"] = "wallpapers/builtin/blank-light.png"
        source = self.user / "themes/wallpaper-owner.json"
        source.write_text(json.dumps(theme), encoding="utf-8")

        listed = wallpapers.migrate_theme_wallpapers()

        self.assertEqual("Built in", listed[0]["kind"])
        self.assertEqual("wallpapers/builtin/blank-light.png", json.loads(source.read_text())["wallpaper"]["path"])
        self.assertFalse((self.user / "wallpapers").exists())

    def test_unsafe_or_non_image_sources_do_not_create_library_files(self) -> None:
        text = self.root / "not-an-image.png"
        text.write_bytes(b"plain text")
        with self.assertRaisesRegex(wallpapers.WallpaperFailure, "PNG, JPEG, or WebP"):
            wallpapers.import_wallpaper(text, "wallpaper-owner")

        link = self.root / "link.png"
        link.symlink_to(text)
        with self.assertRaisesRegex(wallpapers.WallpaperFailure, "symlinks"):
            wallpapers.import_wallpaper(link, "wallpaper-owner")
        self.assertFalse((self.user / "wallpapers").exists())


if __name__ == "__main__":
    unittest.main()
