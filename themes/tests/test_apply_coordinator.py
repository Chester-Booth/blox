"""Injected owner outcomes for the Apply transaction boundary."""
from __future__ import annotations

import copy
import base64
import json
import tempfile
import unittest
from pathlib import Path

from shell.scripts.settings_document import SettingsDocument
from themes.lib.blox_theme.apply_coordinator import ApplyCoordinator, ApplyError, BeforeCoreMutationFailure, BeforeTargetPublicationFailure, JOURNAL_LIMIT
from themes.lib.blox_theme.composition import CompositionDocument, component_digest


class Owner:
    independent = True

    def __init__(self, name, component_id=None):
        self.name = name
        self.component_id = component_id
        self.value = {"old": name}
        self.fail = False
        self.result_state = "success"
        self.retry_safe = True
        self.restore_safe = True
        self.calls = []

    def validate(self, request, settings, *args):
        self.calls.append("validate")

    def capture(self):
        self.calls.append("capture")
        return copy.deepcopy(self.value)

    def validate_image(self, image):
        if not isinstance(image, dict):
            raise ValueError("bad image")

    def apply(self, request):
        self.calls.append("apply")
        self.value = {"new": self.name}
        if self.fail:
            raise RuntimeError(f"{self.name} failed")
        return {"state": self.result_state, "digest": component_digest(self.value),
                "revision": 1, "generationId": "fixture-generation"}

    def observe(self):
        self.calls.append("observe")
        return {"digest": component_digest(self.value), "revision": 1}

    def restore(self, image):
        self.calls.append("restore")
        self.value = copy.deepcopy(image)

    def verify_restored(self, image):
        if self.value != image:
            raise RuntimeError("restore mismatch")

    def can_retry(self, image):
        return self.retry_safe

    def can_restore(self, image):
        return self.restore_safe


class Core(Owner):
    def validate(self, request, settings, selected):
        super().validate(request, settings)
        if request["sourceDigest"] != "a" * 64:
            raise ValueError("source changed")

    def verify(self, request):
        self.calls.append("verify")
        if self.fail:
            raise RuntimeError("activation failed")


class SettingsCore(Core):
    def __init__(self, document, root):
        super().__init__("core")
        self.document = document
        self.directory = root / "config/blox"

    def capture(self):
        image = super().capture()
        return {"value": image, "files": {
            name: base64.b64encode((self.directory / name).read_bytes()).decode()
            if (self.directory / name).exists() else None
            for name in ("settings.json", "settings.json.bak")
        }}

    def apply(self, request):
        changed = self.document.set("bar.layout.position", "right", request["settingsRevision"])
        if not changed.ok:
            raise RuntimeError(f"Settings failed: {changed.code}")
        return super().apply(request)

    def restore(self, image):
        super().restore(image["value"])
        for name, contents in image["files"].items():
            path = self.directory / name
            if contents is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(base64.b64decode(contents))
                path.chmod(0o600)

    def verify_restored(self, image):
        super().verify_restored(image["value"])
        for name, contents in image["files"].items():
            path = self.directory / name
            actual = base64.b64encode(path.read_bytes()).decode() if path.exists() else None
            if actual != contents:
                raise RuntimeError(f"Settings pre-image differs: {name}")


class ApplyCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "config").mkdir(mode=0o700)
        self.settings = SettingsDocument(self.root / "config")
        for target in ("kitty", "wallpaper"):
            result = self.settings.set(f"targets.{target}.enabled", True,
                                       self.settings.get().revision)
            self.assertTrue(result.ok, result)
        self.ledger = CompositionDocument(self.root / "state")
        self.core = Core("core")
        self.owners = {"kitty": Owner("kitty", "appearance"),
                       "wallpaper": Owner("wallpaper", "wallpaper")}
        self.coordinator = ApplyCoordinator(self.settings, self.ledger,
                                             self.root / "journal", self.core, self.owners)
        self.request = {"settingsRevision": self.settings.get().revision,
                        "themeId": "fixture", "sourceDigest": "a" * 64,
                        "components": {"kitty": "appearance", "wallpaper": "wallpaper"},
                        "approvals": {}}
        self.expected = json.loads((Path(__file__).parent / "fixtures/apply/outcomes.json").read_text())

    def test_retry_reserves_record_growth_before_owner_mutation(self):
        self.owners['kitty'].fail = True
        self.coordinator.apply(self.request)
        dfd, fd = self.coordinator._lock()
        try:
            record = self.coordinator._read(dfd)
            record['legacyEvidence'] = 'x' * (JOURNAL_LIMIT - 100 * 1024)
            self.coordinator._write(dfd, record)
        finally:
            self.coordinator._unlock(dfd, fd)
        calls = list(self.owners['kitty'].calls)
        before = (self.root / 'journal/apply.json').read_bytes()
        with self.assertRaisesRegex(ApplyError, 'recovery size budget'):
            self.coordinator.retry_failed_targets()
        self.assertEqual(self.owners['kitty'].calls, calls + ['validate'])
        self.assertEqual((self.root / 'journal/apply.json').read_bytes(), before)

    def test_before_publication_failure_binds_original_and_never_restores_foreign_state(self):
        owner = self.owners['kitty']
        original_capture = owner.capture
        captures = []
        bindings = []
        def bind(image, result):
            bindings.append(copy.deepcopy(image))
        def capture():
            if captures:
                owner.value = {'foreign': 'new selection'}
            image = original_capture()
            captures.append(image)
            return image
        def reject(request):
            raise BeforeTargetPublicationFailure('selection changed before publication')
        def generation_only(image):
            durable = json.loads((self.root / 'journal/apply.json').read_text())
            self.assertTrue(durable['targets']['kitty']['publicationConflict'])
            self.assertEqual(durable['targets']['kitty']['state'], 'failure')
            self.assertEqual(image, {'foreign': 'new selection'})
        owner.bind_transaction_image = bind
        owner.capture = capture
        owner.apply = reject
        owner.restore_before_publication_failure = generation_only
        result = self.coordinator.apply(self.request)
        self.assertEqual(bindings, [{'old': 'kitty'}])
        self.assertEqual(owner.value, {'foreign': 'new selection'})
        self.assertNotIn('restore', owner.calls)
        self.assertTrue(result['observationConflict'])
        self.assertEqual(result['actions'], {'retryFailedTargets': [], 'keepSuccessfulChanges': False,
                                           'rollBack': False, 'cancel': False, 'abandonSuperseded': True})
        self.coordinator.abandon_superseded_partial()
        self.assertEqual(owner.value, {'foreign': 'new selection'})

    def test_cold_retry_rebinds_durable_image_before_new_local_capture(self):
        self.owners['kitty'].fail = True
        self.coordinator.apply(self.request)
        owner = self.owners['kitty']
        bindings = []
        def bind(image, result):
            bindings.append(copy.deepcopy(image))
        def capture():
            self.assertEqual(bindings, [{'old': 'kitty'}])
            owner.value = {'foreign': 'new selection'}
            return copy.deepcopy(owner.value)
        def reject(request):
            raise BeforeTargetPublicationFailure('selection changed before publication')
        owner.bind_transaction_image = bind
        owner.capture = capture
        owner.apply = reject
        owner.restore_before_publication_failure = lambda image: None
        cold = ApplyCoordinator(self.settings, self.ledger, self.root / 'journal', self.core, self.owners)
        result = cold.retry_failed_targets()
        self.assertTrue(result['observationConflict'])
        self.assertEqual(owner.value, {'foreign': 'new selection'})
        self.assertTrue(result['actions']['abandonSuperseded'])

    def test_keep_retains_restart_followup_after_verified_publication(self):
        self._assert_keep_followup('restart')

    def test_keep_retains_manual_followup_after_verified_publication(self):
        self._assert_keep_followup('manual')

    def _assert_keep_followup(self, state):
        self.owners['kitty'].result_state = state
        self.owners['wallpaper'].fail = True
        result = self.coordinator.apply(self.request)
        self.assertTrue(result['actions']['keepSuccessfulChanges'])
        before = self.ledger.read()
        kept = self.coordinator.keep_successful_changes()
        self.assertEqual(kept['targets']['kitty']['state'], state)
        self.assertEqual(self.owners['kitty'].value, {'new': 'kitty'})
        self.assertEqual(self.ledger.read(), before)
        self.assertEqual(before['components']['appearance']['status'], 'pending')
        self.assertFalse((self.root / 'journal/apply.json').exists())

    def test_before_mutation_conflict_preserves_competing_changes_and_releases_receipt(self):
        def conflict(request):
            change = self.settings.set('bar.layout.position', 'right', self.settings.get().revision)
            self.assertTrue(change.ok)
            self.owners['kitty'].value = {'foreign': 'kitty'}
            raise BeforeCoreMutationFailure('Settings changed before core activation')
        self.core.apply = conflict
        result = self.coordinator.apply(self.request)
        self.assertEqual(result['code'], 'before-write-failure')
        self.assertTrue(result['journalReleased'])
        self.assertEqual(self.settings.get().data['bar']['layout']['position'], 'right')
        self.assertEqual(self.owners['kitty'].value, {'foreign': 'kitty'})
        self.assertNotIn('restore', self.core.calls)
        self.assertTrue(all('restore' not in owner.calls for owner in self.owners.values()))
        self.assertFalse((self.root / 'journal/apply.json').exists())

    def test_interrupted_before_mutation_release_never_restores_on_cold_recovery(self):
        def conflict(request):
            self.settings.set('bar.layout.position', 'right', self.settings.get().revision)
            raise BeforeCoreMutationFailure('Settings changed before core activation')
        self.core.apply = conflict
        original_write = self.coordinator._write
        def interrupted(dfd, record, filename='apply.json'):
            if record is None:
                raise OSError('release interrupted')
            return original_write(dfd, record, filename)
        self.coordinator._write = interrupted
        with self.assertRaisesRegex(OSError, 'release interrupted'):
            self.coordinator.apply(self.request)
        self.coordinator._write = original_write
        cold = ApplyCoordinator(self.settings, self.ledger, self.root / 'journal', self.core, self.owners)
        self.assertTrue(cold.recover())
        self.assertEqual(self.settings.get().data['bar']['layout']['position'], 'right')
        self.assertNotIn('restore', self.core.calls)
        self.assertTrue(all('restore' not in owner.calls for owner in self.owners.values()))

    def assert_outcome(self, result, fixture):
        projection = {
            "code": result["code"],
            "phase": result["phase"],
            "states": {name: item["state"] for name, item in result["targets"].items()},
            "actions": result["actions"],
            "ledger": {name: self.ledger.read()["components"][name]["status"]
                       for name in ("appearance", "wallpaper")},
        }
        self.assertEqual(projection, self.expected[fixture])

    def test_finished_run_releases_journal_for_the_next_apply(self):
        events = []
        self.coordinator.event_sink = events.append
        result = self.coordinator.apply(self.request)
        self.assertEqual(result["phase"], "complete")
        self.assertEqual(events, self.coordinator.trace)
        self.coordinator.finish()
        self.assertIsNone(self.coordinator.status())
        again = self.coordinator.apply(self.request)
        self.assertEqual(again["phase"], "complete")

    def test_large_preimage_is_not_duplicated_and_every_followup_remains_readable(self):
        self.owners["kitty"].value = {"large": "x" * 2_200_000}
        original = copy.deepcopy(self.owners["kitty"].value)
        self.assertEqual(self.coordinator.apply(self.request)["phase"], "complete")
        journal = self.root / "journal/apply.json"
        record = json.loads(journal.read_text())
        self.assertNotIn("localImages", record)
        self.assertLess(journal.stat().st_size, JOURNAL_LIMIT)
        self.assertEqual(self.coordinator.status()["phase"], "complete")
        self.assertEqual(self.coordinator.roll_back()["code"], "rolled-back")
        self.assertEqual(self.owners["kitty"].value, original)
        self.assertIsNone(self.coordinator.status())
        self.assertEqual(self.coordinator.apply(self.request)["phase"], "complete")
        self.assertTrue(self.coordinator.finish()["journalReleased"])

    def test_aggregate_bound_and_growth_reserve_reject_before_any_owner_mutates(self):
        for amount in (JOURNAL_LIMIT, JOURNAL_LIMIT - 128 * 1024):
            with self.subTest(amount=amount):
                self.owners["kitty"].value = {"large": "x" * amount}
                for owner in [self.core, *self.owners.values()]: owner.calls.clear()
                with self.assertRaisesRegex(ApplyError, "aggregate journal size"):
                    self.coordinator.apply(self.request)
                self.assertFalse((self.root / "journal/apply.json").exists())
                for owner in [self.core, *self.owners.values()]:
                    self.assertNotIn("apply", owner.calls)
                    self.assertNotIn("restore", owner.calls)

    def test_writer_rejects_oversize_without_replacing_readable_receipt(self):
        self.coordinator.apply(self.request)
        journal = self.root / "journal/apply.json"
        before = journal.read_bytes()
        dfd, fd = self.coordinator._lock()
        try:
            record = self.coordinator._read(dfd)
            record["unexpected"] = "x" * JOURNAL_LIMIT
            with self.assertRaisesRegex(ApplyError, "aggregate size limit"):
                self.coordinator._write(dfd, record)
        finally:
            self.coordinator._unlock(dfd, fd)
        self.assertEqual(journal.read_bytes(), before)
        self.assertEqual(self.coordinator.status()["phase"], "complete")

    def test_large_failure_message_keeps_partial_receipt_and_rollback_readable(self):
        self.owners["kitty"].value = {"large": "x" * 2_200_000}
        def failed(request):
            self.owners["kitty"].value = {"mutated": True}
            raise RuntimeError("x" * JOURNAL_LIMIT)
        self.owners["kitty"].apply = failed
        result = self.coordinator.apply(self.request)
        self.assertEqual(result["phase"], "partial")
        self.assertLessEqual(len(result["targets"]["kitty"]["message"].encode()), 2048)
        self.assertEqual(self.coordinator.status()["phase"], "partial")
        self.assertEqual(self.coordinator.roll_back()["code"], "rolled-back")

    def test_superseded_partial_acknowledgement_preserves_current_state_and_records_failure(self):
        self.owners["kitty"].fail = True
        self.coordinator.apply(self.request)
        current = self.settings.get()
        self.assertTrue(self.settings.set("bar.layout.position", "bottom", current.revision).ok)
        self.core.value = {"foreign": "new core"}
        self.owners["wallpaper"].value = {"foreign": "new wallpaper"}
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()
                  and path.name not in ("apply.json", "apply.lock")}
        values = [copy.deepcopy(owner.value) for owner in [self.core, *self.owners.values()]]
        status = self.coordinator.status()
        self.assertTrue(status["actions"]["abandonSuperseded"])
        released = self.coordinator.abandon_superseded_partial()
        self.assertEqual(released["code"], "abandoned")
        self.assertTrue(released["journalReleased"])
        self.assertIsNone(self.coordinator.status())
        for path, contents in before.items(): self.assertEqual(path.read_bytes(), contents)
        self.assertEqual([owner.value for owner in [self.core, *self.owners.values()]], values)
        receipts = list((self.root / "journal").glob("superseded-*.json"))
        self.assertEqual(len(receipts), 1)
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(receipt["code"], "superseded-partial")
        self.assertFalse(receipt["restorationAttempted"])
        self.assertEqual(receipt["targets"]["kitty"]["state"], "failure")
        self.owners["kitty"].fail = False
        self.assertEqual(self.coordinator.apply({**self.request, "settingsRevision": self.settings.get().revision})["phase"], "complete")

    def test_current_partial_cannot_be_abandoned_and_archive_failure_keeps_journal(self):
        self.owners["kitty"].fail = True
        self.coordinator.apply(self.request)
        with self.assertRaisesRegex(ApplyError, "partial Apply is current"):
            self.coordinator.abandon_superseded_partial()
        self.settings.set("bar.layout.position", "bottom", self.settings.get().revision)
        journal = self.root / "journal/apply.json"
        transaction = json.loads(journal.read_text())["id"]
        archive = journal.parent / ("superseded-" + transaction + ".json")
        archive.write_text("personal replacement")
        with self.assertRaisesRegex(ApplyError, "receipt has changed"):
            self.coordinator.abandon_superseded_partial()
        self.assertTrue(journal.exists())
        self.assertEqual(archive.read_text(), "personal replacement")

    def test_stale_complete_receipt_can_be_acknowledged_without_restoring_current_state(self):
        self.coordinator.apply(self.request)
        path = self.settings.root / "blox/settings.json"
        current = json.loads(path.read_text())
        revision = current["revision"]
        current["bar"]["layout"]["position"] = "bottom"
        path.write_text(json.dumps(current))
        self.assertEqual(self.settings.get().revision, revision)
        self.core.value = {"foreign": "current core"}
        self.owners["kitty"].value = {"foreign": "current owner"}
        before_files = {p: p.read_bytes() for p in self.root.rglob("*")
                        if p.is_file() and p.name != "apply.lock"}
        before_core = copy.deepcopy(self.core.value)
        before_owners = {name: copy.deepcopy(owner.value) for name, owner in self.owners.items()}
        status = self.coordinator.status()
        self.assertEqual(status["phase"], "complete")
        self.assertEqual(status["code"], "observation-conflict")
        self.assertTrue(status["observationConflict"])
        self.assertFalse(status["recoveryAvailable"])
        self.assertEqual(status["actions"], {"retryFailedTargets": [], "keepSuccessfulChanges": False,
                                           "rollBack": False, "cancel": False})
        with self.assertRaisesRegex(ApplyError, "Settings changed since Apply"):
            self.coordinator.roll_back()
        released = self.coordinator.finish()
        self.assertTrue(released["journalReleased"])
        self.assertTrue(released["observationConflict"])
        self.assertIsNone(self.coordinator.status())
        for file, contents in before_files.items():
            if file.name != "apply.json": self.assertEqual(file.read_bytes(), contents, str(file))
        self.assertEqual(self.core.value, before_core)
        self.assertEqual({name: owner.value for name, owner in self.owners.items()}, before_owners)
        request = {**self.request, "settingsRevision": revision}
        self.assertEqual(self.coordinator.apply(request)["phase"], "complete")

    def test_unreadable_current_owner_does_not_turn_complete_receipt_into_recovery(self):
        self.coordinator.apply(self.request)
        before_core = copy.deepcopy(self.core.value)
        def unreadable(): raise OSError("current owner cannot be read")
        self.core.observe = unreadable
        status = self.coordinator.status()
        self.assertEqual(status["phase"], "complete")
        self.assertTrue(status["observationConflict"])
        self.assertFalse(status["actions"]["rollBack"])
        self.assertFalse(status["recoveryAvailable"])
        self.assertTrue(self.coordinator.finish()["journalReleased"])
        self.assertEqual(self.core.value, before_core)
        self.assertIsNone(self.coordinator.status())

    def test_stale_partial_receipt_keeps_all_restoration_and_commit_guards(self):
        self.owners["kitty"].fail = True
        self.coordinator.apply(self.request)
        current = self.settings.get()
        self.assertTrue(self.settings.set("bar.layout.position", "bottom", current.revision).ok)
        status = self.coordinator.status()
        self.assertEqual(status["phase"], "partial")
        self.assertTrue(status["observationConflict"])
        self.assertFalse(status["actions"]["rollBack"])
        self.assertEqual(status["actions"]["retryFailedTargets"], [])
        self.assertFalse(status["actions"]["keepSuccessfulChanges"])
        for operation in (self.coordinator.roll_back, self.coordinator.retry_failed_targets,
                          self.coordinator.keep_successful_changes, self.coordinator.finish):
            with self.assertRaises(ApplyError): operation()
        self.assertTrue((self.root / "journal/apply.json").exists())

    def test_finish_rejects_unresolved_partial_commit(self):
        self.owners["kitty"].fail = True
        self.coordinator.apply(self.request)
        with self.assertRaises(ApplyError):
            self.coordinator.finish()
        self.assertIsNotNone(self.coordinator.status())

    def test_rollback_restores_absent_composition_document(self):
        before = self.ledger.capture_preimage()
        self.assertIsNone(before["bytes"])
        self.coordinator.apply(self.request)
        self.assertIsNotNone(self.ledger.capture_preimage()["bytes"])
        self.coordinator.roll_back()
        self.assertEqual(self.ledger.capture_preimage(), before)

    def test_rollback_restores_exact_composition_bytes_mode_and_revision(self):
        self.ledger.update(lambda value: value, expected_revision=0)
        path = self.root / "state/blox/theme/composition.json"
        path.write_text(json.dumps(self.ledger.read(), indent=2) + "\n")
        path.chmod(0o400)
        before = self.ledger.capture_preimage()
        self.coordinator.apply(self.request)
        self.coordinator.roll_back()
        self.assertEqual(self.ledger.capture_preimage(), before)

    def test_core_failure_restores_all_and_offers_no_rollback(self):
        self.core.fail = True
        before = self.ledger.read()
        result = self.coordinator.apply(self.request)
        self.assert_outcome(result, "coreFailure")
        self.assertEqual([event["stage"] for event in self.coordinator.trace], [
            "journal-durable", "core-failed", "restore-started", "owner-restored",
            "owner-restored", "core-restored", "restore-complete",
        ])
        self.assertEqual(result["code"], "core-failure")
        self.assertEqual(self.core.value, {"old": "core"})
        self.assertEqual(self.owners["kitty"].value, {"old": "kitty"})
        self.assertFalse(result["actions"]["rollBack"])
        self.assertFalse((self.root / "journal/apply.json").exists())
        self.assertEqual({key: value["status"] for key, value in self.ledger.read()["components"].items()},
                         {key: value["status"] for key, value in before["components"].items()})

    def test_settings_commit_then_core_failure_restores_exact_file_bytes(self):
        self.core = SettingsCore(self.settings, self.root)
        self.core.fail = True
        self.coordinator.core = self.core
        before = self.core.capture()
        result = self.coordinator.apply(self.request)
        self.assertEqual(result["code"], "core-failure")
        self.core.verify_restored(before)
        self.assertEqual(self.settings.get().revision, self.request["settingsRevision"])
        self.assertFalse(result["actions"]["rollBack"])

    def test_independent_failure_retry_and_partial_commit(self):
        self.owners["kitty"].fail = True
        result = self.coordinator.apply(self.request)
        self.assert_outcome(result, "independentFailure")
        self.assertEqual([(event["stage"], event.get("target"), event.get("state"))
                          for event in self.coordinator.trace], [
            ("journal-durable", None, None), ("core-verified", None, None),
            ("target-result", "kitty", "failure"),
            ("target-result", "wallpaper", "success"),
            ("ledger-committed", None, None),
        ])
        self.assertEqual(result["code"], "partial")
        self.assertEqual(result["targets"]["kitty"]["state"], "failure")
        self.assertEqual(result["targets"]["wallpaper"]["state"], "success")
        self.assertEqual(self.owners["kitty"].value, {"old": "kitty"})
        self.assertEqual(result["actions"]["retryFailedTargets"], ["kitty"])
        self.assertTrue(result["actions"]["keepSuccessfulChanges"])
        self.assertTrue(result["actions"]["rollBack"])
        self.assertFalse(result["actions"]["cancel"])
        self.assertEqual(self.ledger.read()["components"]["wallpaper"]["status"], "managed")
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "unknown")
        self.owners["kitty"].fail = False
        retry = self.coordinator.retry_failed_targets()
        self.assert_outcome(retry, "retry")
        self.assertEqual(self.coordinator.trace[0], {"stage": "retry-started", "targets": ["kitty"]})
        self.assertEqual([event.get("target") for event in self.coordinator.trace
                          if event["stage"] == "target-result"], ["kitty"])
        self.assertEqual(retry["code"], "ok")
        self.assertEqual(retry["targets"]["kitty"]["state"], "success")
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "managed")
        self.assertIsNone(self.ledger.read()["activeTheme"])

    def test_keep_only_after_durable_partial_and_rollback_after_activation(self):
        with self.assertRaises(ApplyError):
            self.coordinator.keep_successful_changes()
        with self.assertRaises(ApplyError):
            self.coordinator.roll_back()
        self.owners["kitty"].fail = True
        partial = self.coordinator.apply(self.request)
        self.assertEqual(partial["code"], "partial")
        kept = self.coordinator.keep_successful_changes()
        self.assert_outcome(kept, "kept")
        self.assertEqual(kept["code"], "kept")
        self.assertFalse((self.root / "journal/apply.json").exists())
        self.assertEqual(self.owners["wallpaper"].value, {"new": "wallpaper"})
        self.owners["kitty"].fail = False
        complete = self.coordinator.apply(self.request)
        self.assertEqual(complete["code"], "ok")
        rolled = self.coordinator.roll_back()
        self.assert_outcome(rolled, "rolledBack")
        self.assertEqual(rolled["code"], "rolled-back")
        self.assertFalse(rolled["actions"]["rollBack"])
        self.assertEqual(self.core.value, {"new": "core"})
        self.assertEqual(self.owners["kitty"].value, {"old": "kitty"})
        self.assertEqual(self.owners["wallpaper"].value, {"new": "wallpaper"})
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "unknown")
        self.assertEqual(self.ledger.read()["components"]["wallpaper"]["status"], "managed")

    def test_journal_precedes_mutation_and_recovery_restores_pending(self):
        original = self.core.apply

        def checked_apply(request):
            record = json.loads((self.root / "journal/apply.json").read_text())
            self.assertEqual(record["phase"], "pending")
            self.assertEqual(record["images"]["core"], {"old": "core"})
            return original(request)

        self.core.apply = checked_apply
        self.assertEqual(self.coordinator.apply(self.request)["code"], "ok")
        record = json.loads((self.root / "journal/apply.json").read_text())
        record["phase"] = "pending"
        (self.root / "journal/apply.json").write_text(json.dumps(record))
        self.assertTrue(self.coordinator.recover())
        self.assertEqual(self.owners["kitty"].value, {"old": "kitty"})
        self.assertFalse((self.root / "journal/apply.json").exists())

    def test_validation_and_approval_fail_before_capture(self):
        self.request["settingsRevision"] -= 1
        with self.assertRaisesRegex(ApplyError, "revision conflict"):
            self.coordinator.apply(self.request)
        self.assertEqual(self.core.calls, [])
        self.request["settingsRevision"] += 1
        source = self.root / "script.sh"
        source.write_bytes(b"first")
        self.request["approvals"] = {str(source): "0" * 64}
        with self.assertRaisesRegex(ApplyError, "approved file changed"):
            self.coordinator.apply(self.request)
        self.assertEqual(self.core.calls, [])
        self.assertFalse((self.root / "journal/apply.json").exists())

    def test_ledger_commit_failure_restores_all_owner_preimages(self):
        original = self.ledger.update

        def fail_once(*args, **kwargs):
            self.ledger.update = original
            raise RuntimeError("ledger unavailable")

        self.ledger.update = fail_once
        with self.assertRaisesRegex(RuntimeError, "ledger unavailable"):
            self.coordinator.apply(self.request)
        self.assertEqual(self.core.value, {"old": "core"})
        for name, owner in self.owners.items():
            self.assertEqual(owner.value, {"old": name})
        self.assertFalse((self.root / "journal/apply.json").exists())

    def test_restart_and_manual_results_remain_pending_in_ledger(self):
        self.owners["kitty"].result_state = "restart"
        self.owners["wallpaper"].result_state = "manual"
        result = self.coordinator.apply(self.request)
        self.assertEqual(result["code"], "ok")
        self.assertEqual(result["targets"]["kitty"]["state"], "restart")
        self.assertEqual(result["targets"]["wallpaper"]["state"], "manual")
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "pending")
        self.assertEqual(self.ledger.read()["components"]["wallpaper"]["status"], "pending")
        self.assertEqual(self.ledger.read()["managedComponents"], [])

    def test_shared_component_waits_for_every_target_owner(self):
        self.owners["wallpaper"].component_id = "appearance"
        self.request["components"]["wallpaper"] = "appearance"
        self.owners["kitty"].fail = True
        partial = self.coordinator.apply(self.request)
        self.assertEqual(partial["targets"]["wallpaper"]["state"], "success")
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "unknown")
        self.owners["kitty"].fail = False
        retried = self.coordinator.retry_failed_targets()
        self.assertEqual(retried["targets"]["wallpaper"]["state"], "success")
        self.assertEqual(self.owners["wallpaper"].calls.count("apply"), 1)
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "managed")

    def test_dependent_owner_failure_restores_all_before_independent_work(self):
        self.owners["wallpaper"].independent = False
        self.owners["wallpaper"].fail = True
        result = self.coordinator.apply(self.request)
        self.assertEqual(result["code"], "core-failure")
        self.assertEqual(self.owners["kitty"].calls.count("apply"), 0)
        self.assertEqual(self.owners["wallpaper"].value, {"old": "wallpaper"})
        self.assertEqual(self.core.value, {"old": "core"})
        self.assertEqual(result["actions"]["retryFailedTargets"], [])
        self.assertEqual(result["actions"]["rollBack"], False)

    def test_unavailable_actions_are_not_offered(self):
        self.owners["kitty"].fail = True
        partial = self.coordinator.apply(self.request)
        self.assertEqual(partial["actions"]["retryFailedTargets"], ["kitty"])
        self.owners["kitty"].retry_safe = False
        self.owners["wallpaper"].restore_safe = False
        current = self.coordinator.status()
        self.assertEqual(current["actions"]["retryFailedTargets"], [])
        self.assertFalse(current["actions"]["rollBack"])
        with self.assertRaisesRegex(ApplyError, "no failed target has a safe retry"):
            self.coordinator.retry_failed_targets()
        with self.assertRaisesRegex(ApplyError, "rollback is no longer safe"):
            self.coordinator.roll_back()

    def test_retry_commit_interruption_restores_original_preimages(self):
        self.owners["kitty"].fail = True
        self.assertEqual(self.coordinator.apply(self.request)["code"], "partial")
        self.owners["kitty"].fail = False
        original = self.coordinator._write
        triggered = False

        def interrupt(dfd, record):
            nonlocal triggered
            if record is not None and record["phase"] == "complete" and not triggered:
                triggered = True
                raise OSError("journal publish interrupted")
            return original(dfd, record)

        self.coordinator._write = interrupt
        with self.assertRaisesRegex(OSError, "journal publish interrupted"):
            self.coordinator.retry_failed_targets()
        self.assertTrue(triggered)
        self.assertEqual(self.core.value, {"old": "core"})
        self.assertEqual(self.owners["kitty"].value, {"old": "kitty"})
        self.assertEqual(self.owners["wallpaper"].value, {"old": "wallpaper"})
        self.assertEqual(self.ledger.read()["components"]["appearance"]["status"], "unknown")
        self.assertEqual(self.ledger.read()["components"]["wallpaper"]["status"], "unknown")
        self.assertFalse((self.root / "journal/apply.json").exists())

    def test_unsafe_journal_directory_and_lock_fail_before_owner_actions(self):
        alternate = self.root / "elsewhere"
        alternate.mkdir()
        (self.root / "linked").symlink_to(alternate, target_is_directory=True)
        unsafe = ApplyCoordinator(self.settings, self.ledger, self.root / "linked/journal",
                                  self.core, self.owners)
        with self.assertRaises(OSError):
            unsafe.apply(self.request)
        self.assertEqual(self.core.calls, [])
        journal = self.root / "journal"
        journal.mkdir(mode=0o700)
        (journal / "apply.lock").symlink_to(self.root / "elsewhere/lock")
        with self.assertRaises(OSError):
            self.coordinator.apply(self.request)
        self.assertEqual(self.core.calls, [])

    def test_activation_journal_publish_failure_restores_core(self):
        original = self.coordinator._write

        def fail_active(dfd, record):
            if record is not None and record["phase"] == "active":
                raise OSError("activation journal failed")
            return original(dfd, record)

        self.coordinator._write = fail_active
        with self.assertRaisesRegex(OSError, "activation journal failed"):
            self.coordinator.apply(self.request)
        self.assertEqual(self.core.value, {"old": "core"})
        self.assertEqual(self.owners["kitty"].calls.count("apply"), 0)
        self.assertFalse((self.root / "journal/apply.json").exists())

    def test_retry_accepts_core_committed_settings_revision(self):
        original = self.core.apply

        def commit_settings(request):
            changed = self.settings.set("bar.layout.position", "right", request["settingsRevision"])
            self.assertTrue(changed.ok, changed)
            return original(request)

        self.core.apply = commit_settings
        self.owners["kitty"].fail = True
        partial = self.coordinator.apply(self.request)
        self.assertEqual(partial["code"], "partial")
        self.assertEqual(self.settings.get().revision, self.request["settingsRevision"] + 1)
        self.owners["kitty"].fail = False
        self.assertEqual(self.coordinator.retry_failed_targets()["code"], "ok")


if __name__ == "__main__":
    unittest.main()
