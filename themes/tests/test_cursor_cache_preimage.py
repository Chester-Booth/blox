"""Cursor rollback preserves compiler candidates and checks newly created caches."""
from __future__ import annotations

import copy
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from themes.lib.blox_theme import cursor, runtime, target_preimage
from themes.lib.blox_theme.apply_coordinator import ApplyError


class CursorCachePreimageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        environment = mock.patch.dict(os.environ, {
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_DATA_HOME": str(self.root / "data"),
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.caches = runtime.state_dir() / "cursors"
        self.caches.mkdir(parents=True, mode=0o700)
        self.candidate = self.caches / (".candidate-" + "a" * 64 + "-" + "b" * 32)
        self.candidate.mkdir()
        (self.candidate / "unfinished").write_bytes(b"preserve compiler work")

    def complete_cache(self):
        cache = self.caches / ("c" * 64)
        for name in ("index.theme", "cursors/left_ptr", "manifest.hl", "hyprcursors/left_ptr/meta.hl"):
            path = cache / "theme" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"compiled cursor")
        metadata = {"cache_key": cache.name}
        (cache / "cache.json").write_text(json.dumps({"schema_version": 1,
            "metadata": metadata, "files": cursor._cache_files(cache / "theme")}))
        return cache

    def test_preserves_existing_candidate_and_removes_only_valid_new_cache(self):
        existing = self.caches / ("d" * 64)
        existing.mkdir()
        (existing / "untouched").write_bytes(b"existing cache")
        image = target_preimage.capture("cursor")
        target_preimage.validate("cursor", image)
        new_cache = self.complete_cache()
        target_preimage.restore("cursor", image)
        self.assertFalse(new_cache.exists())
        self.assertEqual((self.candidate / "unfinished").read_bytes(), b"preserve compiler work")
        self.assertEqual((existing / "untouched").read_bytes(), b"existing cache")

    def test_tampered_new_cache_is_preserved_for_manual_recovery(self):
        image = target_preimage.capture("cursor")
        cache = self.complete_cache()
        (cache / "theme/cursors/left_ptr").write_bytes(b"modified externally")
        with self.assertRaisesRegex(ApplyError, "changed before restoration"):
            target_preimage.restore("cursor", image)
        self.assertEqual((cache / "theme/cursors/left_ptr").read_bytes(), b"modified externally")
        self.assertTrue(self.candidate.exists())

    def test_candidate_symlink_is_rejected_without_touching_external_files(self):
        external = self.root / "external"
        external.mkdir()
        (external / "keep").write_bytes(b"external")
        (self.caches / (".candidate-" + "e" * 64 + "-" + "f" * 32)).symlink_to(external)
        with self.assertRaisesRegex(ApplyError, "foreign or unsafe"):
            target_preimage.capture("cursor")
        self.assertEqual((external / "keep").read_bytes(), b"external")

    def test_new_candidate_is_not_deleted_by_rollback(self):
        image = target_preimage.capture("cursor")
        new_candidate = self.caches / (".candidate-" + "e" * 64 + "-" + "f" * 32)
        new_candidate.mkdir()
        with self.assertRaisesRegex(ApplyError, "manual recovery"):
            target_preimage.restore("cursor", image)
        self.assertTrue(new_candidate.exists())

    def test_journal_candidate_names_are_restricted_to_compiler_format(self):
        image = target_preimage.capture("cursor")
        for name in ("../outside", ".candidate-" + "a" * 64, ".candidate-" + "a" * 64 + "-invalid"):
            with self.subTest(name=name):
                invalid = copy.deepcopy(image)
                invalid["cacheKeys"].append(name)
                with self.assertRaisesRegex(ApplyError, "invalid cursor cache pre-image"):
                    target_preimage.validate("cursor", invalid)


if __name__ == "__main__":
    unittest.main()
