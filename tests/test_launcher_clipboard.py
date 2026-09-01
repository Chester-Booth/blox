import importlib.util
import concurrent.futures
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from io import BytesIO
from pathlib import Path

from PIL import Image

MODULE = Path(__file__).parents[1] / "shell/scripts/launcher/clipboard_store.py"
SPEC = importlib.util.spec_from_file_location("clipboard_store", MODULE)
clipboard_store = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(clipboard_store)


class ClipboardStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = clipboard_store.Store(Path(self.temp.name))

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    def test_ingest_deduplicates_and_moves_to_top(self):
        first = self.store.ingest("text/plain", b"one", "one")
        second = self.store.ingest("text/plain", b"two", "two")
        self.assertEqual(first, self.store.ingest("text/plain", b"one", "one"))
        rows, _ = self.store.list()
        self.assertEqual([first, second], [row["id"] for row in rows])
        self.assertEqual(2, rows[0]["use_count"])

    def test_search_tolerates_fts_punctuation(self):
        self.store.ingest("text/plain", b"hello [world]", "hello [world]")
        rows, _ = self.store.list("[world]")
        self.assertEqual(1, len(rows))

    def test_pin_and_remove_payload(self):
        item_id = self.store.ingest("image/png", b"png", "image")
        self.store.pin(item_id, True)
        self.assertIsNotNone(self.store.list()[0][0]["pinned_at"])
        payload = self.store.payloads / self.store.item(item_id)["payload_path"]
        self.store.remove(item_id)
        self.assertFalse(payload.exists())

    def test_image_rows_expose_a_local_preview_uri(self):
        self.store.ingest("image/png", b"\x89PNG\r\n\x1a\nimage", "image")
        row = self.store.list()[0][0]
        self.assertTrue(row["payload_uri"].startswith("file://"))
        self.assertEqual("", self.store.ingest("text/plain", b"text", "text") and self.store.list()[0][0]["payload_uri"])

    def test_file_uri_rows_expose_the_path_and_file_size(self):
        attached = Path(self.temp.name) / "notes.txt"
        attached.write_bytes(b"some notes")
        self.store.ingest("text/uri-list", (attached.as_uri() + "\n").encode(), attached.as_uri())
        row = self.store.list()[0][0]
        self.assertEqual(str(attached), row["file_path"])
        self.assertEqual(10, row["file_size"])
        self.assertEqual("file-text", row["file_icon"])

    def test_file_icons_cover_common_formats_and_have_a_generic_fallback(self):
        expected = {
            "bundle.zip": "file-archive",
            "source.tar.gz": "file-archive",
            "page.html": "file-html",
            "readme.md": "file-md",
            "photo.webp": "file-image",
            "script.qml": "file-code",
            "unknown.blox": "file",
        }
        for name, icon in expected.items():
            with self.subTest(name=name):
                self.assertEqual(icon, clipboard_store.file_icon(Path(name)))

    def test_file_cards_use_the_phosphor_file_icon(self):
        repository = Path(__file__).parents[1]
        picker = (repository / "shell/modules/ClipboardPicker.qml").read_text(encoding="utf-8")
        self.assertIn('iconName: modelData.file_icon || "file"', picker)
        assets = repository / "shell/assets/phosphor"
        icons = set(clipboard_store.FILE_ICON_EXTENSIONS.values()) | set(clipboard_store.FILE_ICON_NAMES.values()) | {"file"}
        self.assertEqual([], [icon for icon in sorted(icons) if not (assets / f"{icon}.svg").exists()])

    def test_rejects_empty_and_oversized_payloads(self):
        self.assertIsNone(self.store.ingest("text/plain", b""))
        self.assertIsNone(self.store.ingest("text/plain", b"x" * (clipboard_store.MAX_PAYLOAD + 1)))

    def test_failed_metadata_write_leaves_no_payload(self):
        self.store.db.close()
        with self.assertRaises(sqlite3.ProgrammingError):
            self.store.ingest("text/plain", b"orphan", "orphan")
        self.assertEqual([], list(self.store.payloads.iterdir()))

    def test_clear_removes_only_unpinned_rows_and_payloads(self):
        pinned = self.store.ingest("text/plain", b"pinned", "pinned")
        self.store.pin(pinned, True)
        pinned_payload = self.store.payloads / self.store.item(pinned)["payload_path"]
        self.store.ingest("text/plain", b"one", "one")
        self.store.ingest("image/png", b"image", "image")
        self.assertEqual(2, self.store.clear())
        self.assertEqual([pinned], [row["id"] for row in self.store.list()[0]])
        self.assertEqual([pinned_payload], list(self.store.payloads.iterdir()))

    def test_pages_use_an_exclusive_cursor(self):
        for value in range(6):
            self.store.ingest("text/plain", str(value).encode(), str(value))
        first, cursor = self.store.list(limit=3)
        second, next_cursor = self.store.list(limit=3, cursor=cursor)
        self.assertEqual(3, len(first))
        self.assertEqual(3, len(second))
        self.assertIsNone(next_cursor)
        self.assertEqual(6, len({row["id"] for row in first + second}))

    def test_pages_follow_pin_and_recency_sort_without_duplicates(self):
        identifiers = [self.store.ingest("text/plain", str(value).encode(), str(value)) for value in range(8)]
        for index in (0, 7, 2, 5, 1):
            self.store.pin(identifiers[index], True)
        expected = [row["id"] for row in self.store.list(limit=100)[0]]
        actual = []
        cursor = None
        while True:
            rows, cursor = self.store.list(limit=2, cursor=cursor)
            actual.extend(row["id"] for row in rows)
            if cursor is None:
                break
        self.assertEqual(expected, actual)

    def test_rejects_invalid_cursor(self):
        with self.assertRaisesRegex(ValueError, "invalid clipboard cursor"):
            self.store.list(cursor="not-a-cursor")

    def test_retention_keeps_pins_and_removes_trimmed_payloads_after_commit(self):
        original_limit = clipboard_store.MAX_UNPINNED_BYTES
        clipboard_store.MAX_UNPINNED_BYTES = 5
        try:
            pinned = self.store.ingest("text/plain", b"pin", "pin")
            self.store.pin(pinned, True)
            old = self.store.ingest("text/plain", b"old", "old")
            newest = self.store.ingest("text/plain", b"new", "new")
            rows, _ = self.store.list()
            self.assertEqual({pinned, newest}, {row["id"] for row in rows})
            with self.assertRaises(KeyError):
                self.store.item(old)
            self.assertEqual(2, len(list(self.store.payloads.iterdir())))
        finally:
            clipboard_store.MAX_UNPINNED_BYTES = original_limit

    def test_maintenance_removes_only_orphans(self):
        item_id = self.store.ingest("text/plain", b"kept", "kept")
        orphan = self.store.payloads / "orphan"
        orphan.write_bytes(b"unused")
        self.assertEqual(1, self.store.maintenance())
        self.assertFalse(orphan.exists())
        self.assertTrue((self.store.payloads / self.store.item(item_id)["payload_path"]).exists())

    def test_private_permissions_and_future_schema_rejection(self):
        self.assertEqual(0o700, self.store.root.stat().st_mode & 0o777)
        self.assertEqual(0o700, self.store.payloads.stat().st_mode & 0o777)
        self.store.db.close()
        database = self.store.root / "history.sqlite3"
        connection = sqlite3.connect(database)
        connection.execute("PRAGMA user_version=999")
        connection.close()
        with self.assertRaisesRegex(RuntimeError, "newer than supported"):
            clipboard_store.Store(self.store.root)

    def test_cli_skips_sensitive_and_unsupported_image_data(self):
        command = MODULE.with_name("clipboardctl.py")
        root = Path(self.temp.name) / "cli"
        sensitive = subprocess.run(
            [sys.executable, command, "--root", root, "ingest", "--mime", "text/plain"],
            input=b"secret",
            capture_output=True,
            env={**os.environ, "CLIPBOARD_STATE": "sensitive", "XDG_RUNTIME_DIR": self.temp.name},
            check=False,
        )
        unsupported = subprocess.run(
            [sys.executable, command, "--root", root, "ingest", "--mime", "image/png"],
            input=b"not an image",
            capture_output=True,
            env={**os.environ, "XDG_RUNTIME_DIR": self.temp.name},
            check=False,
        )
        self.assertEqual("sensitive", json.loads(sensitive.stdout)["skipped"])
        self.assertEqual("unsupported-image", json.loads(unsupported.stdout)["skipped"])
        cli_store = clipboard_store.Store(root)
        try:
            rows, _ = cli_store.list()
            self.assertEqual([], rows)
        finally:
            cli_store.db.close()

    def test_cli_deduplicates_the_plain_text_and_uri_list_views_of_a_file(self):
        command = MODULE.with_name("clipboardctl.py")
        attached = Path(self.temp.name) / "script.py"
        attached.write_text("print('hello')\n")
        environment = {**os.environ, "XDG_RUNTIME_DIR": self.temp.name}
        representations = (
            ("text/plain;charset=utf-8", attached.as_uri().encode()),
            ("text/uri-list", (attached.as_uri() + "\n").encode()),
        )
        for index, order in enumerate((representations, tuple(reversed(representations)))):
            with self.subTest(order=index):
                root = Path(self.temp.name) / f"file-deduplication-{index}"
                for mime, payload in order:
                    result = subprocess.run(
                        [sys.executable, command, "--root", root, "ingest", "--mime", mime],
                        input=payload,
                        capture_output=True,
                        env=environment,
                        check=False,
                    )
                    self.assertEqual(0, result.returncode)

                cli_store = clipboard_store.Store(root)
                try:
                    rows, _ = cli_store.list()
                    self.assertEqual(1, len(rows))
                    self.assertEqual("text/uri-list", rows[0]["mime"])
                    self.assertEqual(str(attached), rows[0]["file_path"])
                finally:
                    cli_store.db.close()

    def test_cli_rejects_images_with_unsafe_decoded_dimensions(self):
        command = MODULE.with_name("clipboardctl.py")
        root = Path(self.temp.name) / "large-image"
        payload = BytesIO()
        Image.new("1", (5000, 4000)).save(payload, format="PNG")
        result = subprocess.run(
            [sys.executable, command, "--root", root, "ingest", "--mime", "image/png"],
            input=payload.getvalue(),
            capture_output=True,
            env={**os.environ, "XDG_RUNTIME_DIR": self.temp.name},
            check=False,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual("unsupported-image", json.loads(result.stdout)["skipped"])

    def test_cli_serialises_concurrent_ingest(self):
        command = MODULE.with_name("clipboardctl.py")
        root = Path(self.temp.name) / "concurrent"
        environment = {**os.environ, "XDG_RUNTIME_DIR": self.temp.name}

        def ingest(value):
            return subprocess.run(
                [sys.executable, command, "--root", root, "ingest", "--mime", "text/plain"],
                input=value.encode(),
                capture_output=True,
                env=environment,
                check=False,
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(ingest, (f"item {index}" for index in range(20))))
        self.assertTrue(all(result.returncode == 0 for result in results))
        concurrent_store = clipboard_store.Store(root)
        try:
            rows, _ = concurrent_store.list(limit=50)
            self.assertEqual(20, len(rows))
        finally:
            concurrent_store.db.close()


if __name__ == "__main__":
    unittest.main()
