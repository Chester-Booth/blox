from __future__ import annotations

import copy
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


THEMES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import load_theme, render_theme, validate_theme
from blox_theme import cursor
from blox_theme.cursor import CursorFailure, _extract_source, build_cursor_cache, cursor_manifest, cursor_metadata, setup_toolchain, toolchain_paths, validate_cursor_cache


class CursorMetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        _, self.theme = load_theme("catppuccin-mocha")

    def test_generated_metadata_and_cache_key_are_deterministic(self) -> None:
        first = cursor_metadata(self.theme)
        second = cursor_metadata(copy.deepcopy(self.theme))
        self.assertEqual(first, second)
        self.assertEqual([22, 24], first["sizes"])
        self.assertEqual("right", first["handedness"])
        self.assertEqual("blox-generated", first["theme_name"])
        changed = copy.deepcopy(self.theme)
        changed["cursor"]["base_colour"] = "#ffffff"
        self.assertNotEqual(first["cache_key"], cursor_metadata(changed)["cache_key"])

    def test_installed_mode_has_no_build_inputs(self) -> None:
        self.theme["cursor"].update(mode="installed", base="Bibata-Modern-Ice")
        metadata = cursor_metadata(self.theme)
        self.assertEqual({"schema_version": 1, "mode": "installed", "theme_name": "Bibata-Modern-Ice", "size": 22}, metadata)
        files, _ = render_theme(self.theme)
        self.assertEqual(metadata, json.loads(files["cursor/metadata.json"]))
        self.assertIn("gtk-cursor-theme-name=Bibata-Modern-Ice", files["gtk/gtk-4.0/settings.ini"])

    def test_invalid_style_is_blocked_and_contrast_is_warned(self) -> None:
        invalid = copy.deepcopy(self.theme)
        invalid["cursor"]["base"] = "Unsupported"
        invalid["cursor"].update(base_colour="#222222", outline_colour="#222222", watch_background="#222222")
        result = validate_theme(invalid, check_dependencies=False)
        self.assertTrue(any("base must" in error for error in result.errors))
        self.assertFalse(any("contrast" in error for error in result.errors))
        self.assertTrue(any("base/outline" in warning for warning in result.warnings))
        self.assertTrue(any("preview surface" in warning for warning in result.warnings))


class CursorCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = mock.patch.dict(os.environ, {
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
        })
        self.environment.start()
        _, theme = load_theme("catppuccin-mocha")
        self.metadata = cursor_metadata(theme)
        paths = toolchain_paths()
        (paths["source"] / "svg/modern-right").mkdir(parents=True)
        (paths["source"] / "svg/modern").mkdir(parents=True)
        (paths["source"] / "configs/right").mkdir(parents=True)
        (paths["source"] / "configs/normal").mkdir(parents=True)
        (paths["source"] / "configs/right/x.build.toml").write_text("[theme]\n", encoding="utf-8")
        (paths["source"] / "configs/normal/x.build.toml").write_text("[theme]\n", encoding="utf-8")
        (paths["source"] / "LICENSE").write_text("GPL-3.0-only\n", encoding="utf-8")
        for name in ("ctgen", "cbmp"):
            paths[name].parent.mkdir(parents=True, exist_ok=True)
            paths[name].write_text("ready\n", encoding="utf-8")
        manifest = cursor_manifest()
        paths["record"].write_text(json.dumps({"schema_version": 1, "source": manifest["bibata"], "tools": {name: manifest[name] for name in ("clickgen", "cbmp")}}), encoding="utf-8")
        lock = paths["root"] / "npm/package-lock.json"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(json.dumps({"packages": {"node_modules/cbmp": {"version": manifest["cbmp"]["version"], "integrity": manifest["cbmp"]["integrity"]}}}), encoding="utf-8")

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def fake_run(self, command: list[str], cwd: Path | None = None, timeout: int = 300):
        if "hyprcursor-util" in Path(command[0]).name:
            output = Path(command[command.index("-o") + 1]) / "extracted_theme"
            (output / "hyprcursors/left_ptr").mkdir(parents=True)
            (output / "manifest.hl").write_text("name = Extracted Theme\ncursors_directory = hyprcursors\n", encoding="utf-8")
            (output / "hyprcursors/left_ptr/meta.hl").write_text("define_size = 22, left_ptr_000.png, 40\n", encoding="utf-8")
        elif "ctgen" in Path(command[0]).name:
            output = Path(command[command.index("-o") + 1]) / "blox-generated"
            (output / "cursors").mkdir(parents=True)
            (output / "index.theme").write_text("[Icon Theme]\nName=blox-generated\n", encoding="utf-8")
            (output / "cursors/left_ptr").write_bytes(b"Xcur-complete")
            (output / "cursors/default").symlink_to("left_ptr")
        else:
            Path(command[command.index("-o") + 1]).mkdir(parents=True)
        return mock.Mock(returncode=0, stdout="", stderr="")

    def test_build_validates_and_then_hits_cache(self) -> None:
        with mock.patch("blox_theme.cursor._checked_run", side_effect=self.fake_run) as runner:
            theme_path, hit = build_cursor_cache(self.metadata)
            self.assertFalse(hit)
            self.assertTrue(validate_cursor_cache(theme_path.parent, self.metadata))
            self.assertTrue((theme_path / "manifest.hl").is_file())
            self.assertTrue((theme_path / "hyprcursors/left_ptr/meta.hl").is_file())
            self.assertEqual(900, runner.call_args_list[0].kwargs["timeout"])
            first_calls = runner.call_count
            again, hit = build_cursor_cache(self.metadata)
        self.assertTrue(hit)
        self.assertEqual(theme_path, again)
        self.assertEqual(first_calls, runner.call_count)

    def test_build_streams_bitmap_and_compiler_progress(self) -> None:
        messages = []

        def fake_bitmap_run(command, source, output, progress, cwd=None, timeout=900):
            output.mkdir(parents=True)
            (output / "wait.png").write_bytes(b"png")
            progress("Rendering wait.svg • 1/164")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch("blox_theme.cursor._checked_run_with_bitmap_progress", side_effect=fake_bitmap_run), mock.patch("blox_theme.cursor._checked_run", side_effect=self.fake_run):
            build_cursor_cache(self.metadata, progress=messages.append)

        self.assertEqual("Rendering wait.svg • 1/164", messages[0])
        self.assertIn("ctgen started", messages)
        self.assertEqual("Validating cursor cache", messages[-1])

    def test_corrupt_cache_is_rejected_without_rebuild(self) -> None:
        with mock.patch("blox_theme.cursor._checked_run", side_effect=self.fake_run):
            theme_path, _ = build_cursor_cache(self.metadata)
        (theme_path / "cursors/left_ptr").write_bytes(b"tampered")
        with self.assertRaisesRegex(CursorFailure, "corrupt"):
            build_cursor_cache(self.metadata)

    def test_left_handed_build_uses_normal_upstream_source(self) -> None:
        _, theme = load_theme("catppuccin-mocha")
        theme["cursor"]["handedness"] = "left"
        metadata = cursor_metadata(theme)
        with mock.patch("blox_theme.cursor._checked_run", side_effect=self.fake_run) as runner:
            build_cursor_cache(metadata)
        commands = [call.args[0] for call in runner.call_args_list]
        self.assertTrue(any(command[command.index("-d") + 1].endswith("svg/modern") for command in commands if "-bc" in command))
        self.assertTrue(any(command[1].endswith("configs/normal/x.build.toml") for command in commands if "ctgen" in command[0]))

    def test_generated_cache_requires_hyprcursor_utility(self) -> None:
        with mock.patch.object(cursor.shutil, "which", side_effect=lambda name: None if name == "hyprcursor-util" else "/usr/bin/available"):
            with self.assertRaisesRegex(CursorFailure, "hyprcursor-util"):
                build_cursor_cache(self.metadata)

    def test_build_failure_removes_partial_candidate(self) -> None:
        with mock.patch("blox_theme.cursor._checked_run", side_effect=CursorFailure("injected compiler failure")):
            with self.assertRaisesRegex(CursorFailure, "injected"):
                build_cursor_cache(self.metadata)
        caches = self.root / "state/blox-theme/cursors"
        self.assertEqual([], list(caches.iterdir()))

    def test_missing_toolchain_is_actionable(self) -> None:
        toolchain_paths()["record"].unlink()
        with self.assertRaisesRegex(CursorFailure, "setup cursor --yes"):
            build_cursor_cache(self.metadata)


class CursorSetupSafetyTests(unittest.TestCase):
    def test_archive_path_traversal_and_links_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, kind in (("traversal", "file"), ("link", "link")):
                archive = root / f"{name}.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    member = tarfile.TarInfo("Bibata_Cursor-2.0.7/../../escape" if kind == "file" else "Bibata_Cursor-2.0.7/link")
                    if kind == "file":
                        content = b"bad"
                        member.size = len(content)
                        bundle.addfile(member, io.BytesIO(content))
                    else:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/etc/passwd"
                        bundle.addfile(member)
                with self.subTest(name=name), self.assertRaises(CursorFailure):
                    _extract_source(archive, root / f"out-{name}", "Bibata_Cursor-2.0.7")

    def test_setup_rejects_bad_source_checksum_before_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(os.environ, {"XDG_DATA_HOME": temporary}):
            def bad_download(url: str, destination: Path) -> None:
                destination.write_bytes(b"not the pinned archive")

            # Claim the toolchain executables exist so the checksum path is
            # reached on machines without npm; the checksum must gate the
            # install regardless of toolchain state.
            with mock.patch.object(cursor.shutil, "which", return_value="/usr/bin/fake"):
                with self.assertRaisesRegex(CursorFailure, "checksum mismatch"):
                    setup_toolchain(download=bad_download)
            self.assertEqual([], list((Path(temporary) / "blox-theme/cursor-toolchain").glob(".*.tmp")))


class CursorCliTests(unittest.TestCase):
    def test_clean_machine_apply_is_actionable_and_non_mutating(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = os.environ.copy()
            environment.update({"XDG_DATA_HOME": str(root / "data"), "XDG_STATE_HOME": str(root / "state")})
            completed = subprocess.run(
                [str(THEMES / "bin/themectl"), "apply", "catppuccin-mocha", "--targets", "cursor", "--json"],
                cwd=THEMES.parent, env=environment, capture_output=True, text=True, check=False,
            )
            response = json.loads(completed.stdout)
            self.assertEqual(3, completed.returncode)
            self.assertTrue(any("setup cursor --yes" in error for error in response["errors"]))
            self.assertFalse((root / "state/blox-theme").exists())

    def test_cursor_setup_requires_confirmation(self) -> None:
        completed = subprocess.run(
            [str(THEMES / "bin/themectl"), "setup", "cursor", "--json"],
            cwd=THEMES.parent, capture_output=True, text=True, check=False,
        )
        self.assertEqual(2, completed.returncode)


if __name__ == "__main__":
    unittest.main()
