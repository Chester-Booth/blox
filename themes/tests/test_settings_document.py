"""Isolated transaction and hostile-path tests for Settings persistence."""

from __future__ import annotations

import copy
import json
import multiprocessing
import os
import socket
import stat
import tempfile
import unittest
from pathlib import Path
from threading import Barrier, Thread
from unittest import mock

from shell.scripts.settings_document import SettingsDocument


def _write_from_process(root, value, start, outcomes):
    start.wait()
    result = SettingsDocument(root).set("bar.layout.position", value, 0)
    outcomes.put((result.ok, result.code))


class SettingsDocumentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "config"
        self.root.mkdir(mode=0o700)
        self.store = SettingsDocument(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_absent_read_does_not_create_file(self):
        result = self.store.get()
        self.assertTrue(result.ok)
        self.assertEqual(0, result.revision)
        self.assertFalse((self.root / "blox" / "settings.json").exists())

    def test_sparse_and_old_documents_migrate_in_memory_then_write(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        path = directory / "settings.json"
        path.write_text(json.dumps({"schemaVersion": 1, "revision": 3, "bar": {"layout": {"position": "right"}}}))
        path.chmod(0o600)
        loaded = self.store.get()
        self.assertTrue(loaded.ok, loaded.data)
        self.assertEqual("right", loaded.data["bar"]["layout"]["position"])
        path.write_text(json.dumps({"schemaVersion": 0, "revision": 7, "bar": {"layout": {"position": "right"}}}))
        path.chmod(0o600)
        loaded = self.store.get()
        self.assertTrue(loaded.ok, loaded.data)
        self.assertEqual(1, loaded.data["schemaVersion"])
        self.assertEqual(7, loaded.revision)
        old_with_unknown = b'{"schemaVersion":0,"revision":7,"foreign":true}'
        path.write_bytes(old_with_unknown)
        self.assertFalse(self.store.get().ok)
        self.assertEqual(old_with_unknown, path.read_bytes())

    def test_future_malformed_and_invalid_files_are_left_intact(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        path = directory / "settings.json"
        for payload in (b'{"schemaVersion":99}', b'{bad json', b'{"schemaVersion":1,"revision":-2}'):
            path.write_bytes(payload)
            path.chmod(0o600)
            result = self.store.get()
            self.assertFalse(result.ok)
            self.assertEqual(payload, path.read_bytes())
            rejected = self.store.set("bar.layout.position", "right", 0)
            self.assertFalse(rejected.ok)
            self.assertEqual(payload, path.read_bytes())

    def test_set_and_section_reset_require_revision_and_validate_whole_candidate(self):
        saved = self.store.set("bar.layout.position", "right", 0)
        self.assertTrue(saved.ok, saved.data)
        self.assertEqual(1, saved.revision)
        conflict = self.store.reset(0, "bar")
        self.assertFalse(conflict.ok)
        self.assertEqual("conflict", conflict.code)
        reset = self.store.reset(1, "bar")
        self.assertTrue(reset.ok, reset.data)
        self.assertEqual(2, reset.revision)
        invalid = self.store.set("bar.layout.position", "sideways", 2)
        self.assertFalse(invalid.ok)
        self.assertEqual(2, self.store.get().revision)
        self.assertEqual("conflict", self.store.reset(1).code)
        whole = self.store.reset(2)
        self.assertTrue(whole.ok, whole.data)
        self.assertEqual(3, whole.revision)

    def test_schema_constraints_hold_with_or_without_jsonschema(self):
        invalid_values = (
            ("power.acProfile", "unsupported"),
            ("autostart", [{"id": "entry", "name": "Entry", "enabled": True,
                             "argv": ["/bin/true"], "delaySeconds": 0}] * 129),
            ("monitors", [{"id": "display", "enabled": True, "width": 1920,
                            "height": 1080, "refreshRate": 0, "x": 0, "y": 0,
                            "scale": 1, "transform": 0}]),
        )
        for path, value in invalid_values:
            with self.subTest(path=path):
                result = self.store.set(path, value, 0)
                self.assertFalse(result.ok)
                self.assertEqual(0, self.store.get().revision)

    def test_two_writers_have_one_commit_and_one_conflict(self):
        outcomes = []
        create_barrier = Barrier(2)
        original_mkdir = os.mkdir
        def overlapping_creation(path, *args, **kwargs):
            if path == "blox" and "dir_fd" in kwargs:
                create_barrier.wait(timeout=5)
            return original_mkdir(path, *args, **kwargs)
        threads = [Thread(target=lambda value=v: outcomes.append(self.store.set("bar.layout.position", value, 0)))
                   for v in ("left", "right")]
        with mock.patch("shell.scripts.settings_document.os.mkdir", side_effect=overlapping_creation):
            for thread in threads: thread.start()
            for thread in threads:
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive())
        self.assertCountEqual(["ok", "conflict"], [result.code for result in outcomes])
        self.assertEqual(1, self.store.get().revision)

    def test_two_processes_with_one_revision_have_one_commit_and_one_conflict(self):
        context = multiprocessing.get_context("fork")
        start = context.Event()
        outcomes = context.Queue()
        writers = [context.Process(target=_write_from_process,
                                   args=(self.root, value, start, outcomes))
                   for value in ("left", "right")]
        for writer in writers:
            writer.start()
        try:
            start.set()
            results = [outcomes.get(timeout=10) for _ in writers]
            for writer in writers:
                writer.join(timeout=10)
                self.assertEqual(0, writer.exitcode)
        finally:
            for writer in writers:
                if writer.is_alive():
                    writer.terminate()
                    writer.join(timeout=10)
            outcomes.close()
        self.assertEqual(1, sum(ok for ok, _ in results))
        self.assertEqual(1, sum(code == "conflict" for _, code in results))
        self.assertEqual(1, self.store.get().revision)
        directory = self.root / "blox"
        self.assertEqual(0, stat.S_IMODE(directory.stat().st_mode) & 0o077)
        self.assertEqual(0, stat.S_IMODE((directory / "settings.lock").stat().st_mode) & 0o077)

    def test_one_valid_preimage_recovers_when_destination_is_missing(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        self.assertTrue(self.store.set("bar.layout.position", "left", 1).ok)
        directory = self.root / "blox"
        self.assertTrue((directory / "settings.json.bak").exists())
        (directory / "settings.json").unlink()
        recovered = self.store.get()
        self.assertTrue(recovered.ok, recovered.data)
        self.assertEqual(1, recovered.revision)
        self.assertEqual("right", recovered.data["bar"]["layout"]["position"])

    def test_valid_backup_recovers_damaged_destination_but_not_future_version(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        self.assertTrue(self.store.set("bar.layout.position", "left", 1).ok)
        path = self.root / "blox" / "settings.json"
        damaged = b"{damaged"
        path.write_bytes(damaged)
        recovered = self.store.get()
        self.assertTrue(recovered.ok, recovered.data)
        self.assertEqual(1, recovered.revision)
        self.assertEqual(damaged, path.read_bytes())
        future = b'{"schemaVersion":99,"revision":2}'
        path.write_bytes(future)
        rejected = self.store.get()
        self.assertFalse(rejected.ok)
        self.assertEqual(future, path.read_bytes())

    def test_recovered_backup_can_be_edited_and_reset_with_exact_corrupt_diagnostics(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        self.assertTrue(self.store.set("bar.layout.position", "left", 1).ok)
        directory = self.root / "blox"
        primary = directory / "settings.json"
        damaged = b"{broken\x00\xff"
        primary.write_bytes(damaged)
        self.assertEqual(self.store.get().revision, 1)
        result = self.store.set("bar.layout.position", "bottom", 1)
        self.assertTrue(result.ok, result)
        self.assertEqual(result.revision, 2)
        diagnostic = list(directory.glob("settings.json.corrupt.*"))
        self.assertEqual(len(diagnostic), 1)
        self.assertEqual(diagnostic[0].read_bytes(), damaged)
        self.assertEqual(diagnostic[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((directory / "settings.json.bak").read_bytes())["revision"], 1)
        primary.write_bytes(b"{broken again")
        reset = self.store.reset(1, "bar")
        self.assertTrue(reset.ok, reset)
        self.assertEqual(reset.revision, 2)
        self.assertEqual(reset.data["bar"], self.store.defaults["bar"])

    def test_corrupt_backup_does_not_block_a_valid_primary_write(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        directory = self.root / "blox"
        backup = directory / "settings.json.bak"
        backup.write_bytes(b"{bad backup")
        backup.chmod(0o600)
        result = self.store.set("bar.layout.position", "bottom", 1)
        self.assertTrue(result.ok, result)
        self.assertEqual(result.revision, 2)
        self.assertEqual(list(directory.glob("settings.json.bak.corrupt.*"))[0].read_bytes(), b"{bad backup")
        self.assertEqual(json.loads(backup.read_bytes())["revision"], 1)

    def test_recovery_conflict_and_future_backup_preserve_every_byte(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        self.assertTrue(self.store.set("bar.layout.position", "left", 1).ok)
        directory = self.root / "blox"
        primary = directory / "settings.json"
        primary.write_bytes(b"{broken")
        self.assertEqual(self.store.set("bar.layout.position", "bottom", 2).code, "conflict")
        self.assertEqual(primary.read_bytes(), b"{broken")
        self.assertEqual(list(directory.glob("*.corrupt.*")), [])
        backup = directory / "settings.json.bak"
        future = b'{"schemaVersion":99,"revision":5}'
        backup.write_bytes(future)
        self.assertFalse(self.store.reset(1).ok)
        self.assertEqual(primary.read_bytes(), b"{broken")
        self.assertEqual(backup.read_bytes(), future)

    def test_interrupted_write_backup_recovers_if_destination_disappears(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        interrupted = SettingsDocument(
            self.root,
            lambda point: (_ for _ in ()).throw(RuntimeError(point))
            if point == "after_backup" else None,
        )
        self.assertEqual("interrupted", interrupted.set("bar.layout.position", "left", 1).code)
        directory = self.root / "blox"
        (directory / "settings.json").unlink()
        recovered = self.store.get()
        self.assertTrue(recovered.ok, recovered.data)
        self.assertEqual(1, recovered.revision)
        self.assertEqual("right", recovered.data["bar"]["layout"]["position"])

    def test_interruption_boundaries_leave_old_or_new_valid_document(self):
        for boundary in ("after_write", "after_file_fsync", "before_backup", "after_backup",
                         "after_replace", "after_directory_fsync"):
            with self.subTest(boundary=boundary):
                root = self.root / boundary
                root.mkdir(mode=0o700)
                original = SettingsDocument(root).set("bar.layout.position", "right", 0)
                self.assertTrue(original.ok)
                path = root / "blox" / "settings.json"
                old = path.read_bytes()
                interrupted = SettingsDocument(root, lambda point: (_ for _ in ()).throw(RuntimeError(point))
                                               if point == boundary else None)
                result = interrupted.set("bar.layout.position", "left", 1)
                self.assertFalse(result.ok)
                self.assertEqual(boundary == "after_directory_fsync", result.committed)
                loaded = SettingsDocument(root).get()
                self.assertTrue(loaded.ok)
                self.assertTrue(path.exists() or (root / "blox" / "settings.json.bak").exists())
                if boundary in ("after_replace", "after_directory_fsync"):
                    self.assertEqual("left", loaded.data["bar"]["layout"]["position"])
                else:
                    self.assertEqual(old, path.read_bytes())

    def test_unsafe_backup_and_destination_swap_are_rejected_without_overwrite(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        directory = self.root / "blox"
        destination = directory / "settings.json"
        original = destination.read_bytes()
        backup = directory / "settings.json.bak"
        target = self.root / "foreign"
        target.write_bytes(b"foreign data")
        backup.symlink_to(target)
        rejected = self.store.set("bar.layout.position", "left", 1)
        self.assertFalse(rejected.ok)
        self.assertEqual("unsafe", rejected.code)
        self.assertEqual(original, destination.read_bytes())
        self.assertTrue(backup.is_symlink())
        self.assertEqual(b"foreign data", target.read_bytes())
        backup.unlink()

        def swap(point):
            if point == "before_backup":
                destination.unlink()
                destination.symlink_to(target)

        rejected = SettingsDocument(self.root, swap).set("bar.layout.position", "left", 1)
        self.assertFalse(rejected.ok)
        self.assertEqual("unsafe", rejected.code)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(b"foreign data", target.read_bytes())
        self.assertFalse(backup.exists())

    def test_fifo_and_socket_documents_and_fifo_lock_fail_closed(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        path = directory / "settings.json"
        os.mkfifo(path, 0o600)
        self.assertEqual("unsafe", self.store.get().code)
        self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertTrue(stat.S_ISFIFO(path.lstat().st_mode))
        path.unlink()

        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path))
            self.assertEqual("unsafe", self.store.get().code)
            self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
            self.assertTrue(stat.S_ISSOCK(path.lstat().st_mode))
        path.unlink()

        lock = directory / "settings.lock"
        lock.unlink()
        os.mkfifo(lock, 0o600)
        self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertTrue(stat.S_ISFIFO(lock.lstat().st_mode))
        self.assertFalse(path.exists())

    def test_symlink_and_hard_link_lock_fail_closed(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        lock = directory / "settings.lock"
        target = self.root / "foreign-lock"
        target.write_bytes(b"foreign lock")
        lock.symlink_to(target)
        self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertTrue(lock.is_symlink())
        self.assertEqual(b"foreign lock", target.read_bytes())
        lock.unlink()
        lock.write_bytes(b"existing lock")
        lock.chmod(0o600)
        os.link(lock, self.root / "lock-alias")
        self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertEqual(b"existing lock", lock.read_bytes())
        self.assertFalse((directory / "settings.json").exists())

    def test_foreign_owner_metadata_rejects_file_lock_and_directory(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        path = directory / "settings.json"
        payload = json.dumps(self.store.defaults).encode()
        path.write_bytes(payload)
        path.chmod(0o600)
        real_fstat = os.fstat

        def foreign_for(name):
            def fstat(fd):
                current = real_fstat(fd)
                if os.readlink(f"/proc/self/fd/{fd}") != str(name):
                    return current
                fields = list(current)
                fields[stat.ST_UID] = os.getuid() + 1
                return os.stat_result(fields)
            return fstat

        with mock.patch("shell.scripts.settings_document.os.fstat", side_effect=foreign_for(path)):
            self.assertEqual("unsafe", self.store.get().code)
            self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertEqual(payload, path.read_bytes())

        lock = directory / "settings.lock"
        with mock.patch("shell.scripts.settings_document.os.fstat", side_effect=foreign_for(lock)):
            self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertEqual(payload, path.read_bytes())

        with mock.patch("shell.scripts.settings_document.os.fstat", side_effect=foreign_for(directory)):
            self.assertEqual("unsafe", self.store.get().code)
            self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertEqual(payload, path.read_bytes())

    def test_device_metadata_is_rejected_without_replacing_the_file(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        path = directory / "settings.json"
        payload = json.dumps(self.store.defaults).encode()
        path.write_bytes(payload)
        path.chmod(0o600)
        real_fstat = os.fstat

        def device_fstat(fd):
            current = real_fstat(fd)
            if os.readlink(f"/proc/self/fd/{fd}") != str(path):
                return current
            fields = list(current)
            fields[stat.ST_MODE] = (fields[stat.ST_MODE] & 0o777) | stat.S_IFCHR
            return os.stat_result(fields)

        with mock.patch("shell.scripts.settings_document.os.fstat", side_effect=device_fstat):
            self.assertEqual("unsafe", self.store.get().code)
            self.assertEqual("unsafe", self.store.set("bar.layout.position", "right", 0).code)
        self.assertEqual(payload, path.read_bytes())

    def test_swap_after_backup_rejects_foreign_destination_and_keeps_preimage(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        directory = self.root / "blox"
        destination = directory / "settings.json"
        target = self.root / "foreign"
        target.write_bytes(b"foreign data")

        def swap(point):
            if point == "after_backup":
                destination.unlink()
                destination.symlink_to(target)

        rejected = SettingsDocument(self.root, swap).set("bar.layout.position", "left", 1)
        self.assertEqual("unsafe", rejected.code)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(b"foreign data", target.read_bytes())
        backup = directory / "settings.json.bak"
        self.assertTrue(backup.exists())
        destination.unlink()
        recovered = self.store.get()
        self.assertTrue(recovered.ok, recovered.data)
        self.assertEqual(1, recovered.revision)

    def test_in_place_edit_during_transaction_is_not_overwritten(self):
        self.assertTrue(self.store.set("bar.layout.position", "right", 0).ok)
        destination = self.root / "blox" / "settings.json"
        foreign = b"changed during transaction"

        def edit(point):
            if point == "before_backup":
                destination.write_bytes(foreign)

        rejected = SettingsDocument(self.root, edit).set("bar.layout.position", "left", 1)
        self.assertEqual("unsafe", rejected.code)
        self.assertEqual(foreign, destination.read_bytes())

    def test_symlink_hardlink_and_directory_symlink_fail_closed(self):
        directory = self.root / "blox"
        directory.mkdir(mode=0o700)
        target = self.root / "outside"
        target.write_text(json.dumps(self.store.defaults))
        path = directory / "settings.json"
        path.symlink_to(target)
        result = self.store.get()
        self.assertFalse(result.ok)
        self.assertEqual(json.dumps(self.store.defaults), target.read_text())
        path.unlink()
        path.write_bytes(json.dumps(self.store.defaults).encode())
        os.link(path, self.root / "alias")
        result = self.store.get()
        self.assertFalse(result.ok)
        path.unlink()
        (directory / "settings.json").symlink_to(target)
        self.assertFalse(self.store.set("bar.enabled", False, 0).ok)
        (directory / "settings.json").unlink()
        alias = self.root / "config-link"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertFalse(SettingsDocument(alias).get().ok)


if __name__ == "__main__":
    unittest.main()
