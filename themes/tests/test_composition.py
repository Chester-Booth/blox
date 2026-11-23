from __future__ import annotations

import copy
import json
import stat
import tempfile
import unittest
from pathlib import Path

from themes.lib.blox_theme.composition import (
    CompositionConflict,
    CompositionDocument,
    CompositionError,
    empty_ledger,
    mark_managed,
    observe_component,
    targets_and_files,
    validate_ledger,
)


FIXTURES = Path(__file__).parent / "fixtures/composition"


class CompositionTests(unittest.TestCase):
    def setUp(self):
        self.managed_fixture = json.loads((FIXTURES / "managed.json").read_text(encoding="utf-8"))

    def managed_ledger(self):
        fixture = self.managed_fixture
        ledger = empty_ledger(fixture["observedAt"])
        for component_id, evidence in fixture["components"].items():
            ledger = mark_managed(
                ledger,
                component_id,
                theme_id=fixture["themeId"],
                source_digest=fixture["sourceDigest"],
                generation_id=fixture["generationId"],
                revision=evidence["revision"],
                digest=evidence["digest"],
                observed_at=fixture["observedAt"],
            )
        return ledger

    def test_managed_fixture_records_observation_and_supported_active_theme(self):
        fixture = self.managed_fixture
        ledger = self.managed_ledger()
        self.assertEqual(ledger["activeTheme"]["themeId"], fixture["expected"]["themeId"])
        self.assertEqual(ledger["activeTheme"]["sourceDigest"], fixture["expected"]["sourceDigest"])
        self.assertEqual(ledger["activeTheme"]["components"], fixture["expected"]["components"])
        for component_id, evidence in fixture["components"].items():
            component = ledger["components"][component_id]
            self.assertEqual(component["status"], "managed")
            self.assertEqual(component["observed"]["revision"], evidence["revision"])
            self.assertEqual(component["observed"]["digest"], evidence["digest"])
            self.assertEqual(component["lastManaged"]["digest"], evidence["digest"])

    def test_external_drift_clears_theme_claim_and_keeps_last_managed_digest(self):
        fixture = json.loads((FIXTURES / "external-drift.json").read_text(encoding="utf-8"))
        ledger = self.managed_ledger()
        prior = copy.deepcopy(ledger["components"][fixture["component"]]["lastManaged"])
        ledger = observe_component(
            ledger,
            fixture["component"],
            revision=fixture["evidence"]["revision"],
            digest=fixture["evidence"]["digest"],
            observed_at=fixture["observedAt"],
        )
        component = ledger["components"][fixture["component"]]
        self.assertEqual(component["status"], fixture["expected"]["status"])
        self.assertIsNone(ledger["activeTheme"])
        self.assertEqual(component["observed"]["digest"], fixture["expected"]["observedDigest"])
        self.assertEqual(component["lastManaged"], prior)
        self.assertEqual(component["lastManaged"]["digest"], fixture["expected"]["lastManagedDigest"])

    def test_unknown_evidence_does_not_reuse_a_stale_theme_claim(self):
        fixture = json.loads((FIXTURES / "unknown-evidence.json").read_text(encoding="utf-8"))
        ledger = self.managed_ledger()
        prior = copy.deepcopy(ledger["components"][fixture["component"]]["lastManaged"])
        ledger = observe_component(
            ledger,
            fixture["component"],
            revision=fixture["evidence"]["revision"],
            digest=fixture["evidence"]["digest"],
            observed_at=fixture["observedAt"],
        )
        component = ledger["components"][fixture["component"]]
        self.assertEqual(component["status"], fixture["expected"]["status"])
        self.assertIsNone(ledger["activeTheme"])
        self.assertIsNone(component["observed"]["digest"])
        self.assertEqual(component["lastManaged"], prior)
        self.assertEqual(component["lastManaged"]["digest"], fixture["expected"]["lastManagedDigest"])

    def test_unavailable_state_preserves_history_without_copying_file_contents(self):
        fixture = json.loads((FIXTURES / "preserved-history.json").read_text(encoding="utf-8"))
        ledger = self.managed_ledger()
        ledger = observe_component(
            ledger,
            fixture["component"],
            revision=fixture["evidence"]["revision"],
            digest=fixture["evidence"]["digest"],
            observed_at=fixture["observedAt"],
            state=fixture["state"],
        )
        component = ledger["components"][fixture["component"]]
        self.assertEqual(component["status"], fixture["expected"]["status"])
        self.assertIsNone(ledger["activeTheme"])
        self.assertEqual(component["lastManaged"], fixture["expected"]["lastManaged"])
        component["observed"]["contents"] = "foreign file contents"
        with self.assertRaises(CompositionError):
            validate_ledger(ledger)

    def test_unmanaged_digest_is_unknown_and_cannot_invent_theme_identity(self):
        ledger = empty_ledger("2026-09-27T10:00:00Z")
        ledger = observe_component(
            ledger,
            "appearance",
            revision=2,
            digest="c" * 64,
            observed_at="2026-09-27T10:01:00Z",
        )
        self.assertEqual(ledger["components"]["appearance"]["status"], "unknown")
        self.assertIsNone(ledger["activeTheme"])
        self.assertIsNone(ledger["components"]["appearance"]["lastManaged"])

    def test_pending_unapplied_and_unavailable_are_distinct_states(self):
        for state in ("pending", "unapplied", "unavailable"):
            with self.subTest(state=state):
                ledger = self.managed_ledger()
                prior = copy.deepcopy(ledger["components"]["bar"]["lastManaged"])
                observed = observe_component(
                    ledger,
                    "bar",
                    revision=None,
                    digest=None,
                    observed_at="2026-09-27T10:08:00Z",
                    state=state,
                )
                component = observed["components"]["bar"]
                self.assertEqual(component["status"], state)
                self.assertEqual(component["lastManaged"], prior)
                if state in ("pending", "unavailable"):
                    self.assertIsNone(observed["activeTheme"])
                else:
                    self.assertIsNotNone(observed["activeTheme"])

    def test_store_is_revisioned_owner_only_and_does_not_write_on_absent_read(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "state"
            document = CompositionDocument(root)
            initial = document.read()
            self.assertEqual(initial["revision"], 0)
            self.assertFalse(root.exists())
            fixture = self.managed_fixture

            def mutation(ledger):
                for component_id, evidence in fixture["components"].items():
                    ledger = mark_managed(
                        ledger,
                        component_id,
                        theme_id=fixture["themeId"],
                        source_digest=fixture["sourceDigest"],
                        generation_id=fixture["generationId"],
                        revision=evidence["revision"],
                        digest=evidence["digest"],
                        observed_at=fixture["observedAt"],
                    )
                return ledger

            saved = document.update(mutation, expected_revision=0)
            path = root / "blox/theme/composition.json"
            self.assertEqual(saved["revision"], 1)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(document.read(), saved)
            with self.assertRaises(CompositionConflict):
                document.update(mutation, expected_revision=0)
            self.assertEqual(document.read(), saved)

    def test_generated_file_projection_uses_each_targets_recorded_source(self):
        fixture = json.loads((FIXTURES / "target-provenance.json").read_text(encoding="utf-8"))
        unknown_ledger = empty_ledger("2026-09-27T10:00:00Z")
        projected = targets_and_files(fixture["generationPath"], fixture["manifest"])
        by_target = {target["target"]: target for target in projected}
        self.assertEqual(fixture["manifest"]["theme_id"], "dracula")
        self.assertEqual(by_target["quickshell"]["themeId"], "catppuccin-mocha")
        self.assertIsNone(unknown_ledger["activeTheme"])
        self.assertFalse(any("activeTheme" in target for target in projected))
        for target_id, expected in fixture["expected"].items():
            target = by_target[target_id]
            self.assertEqual(target["themeId"], expected["themeId"])
            self.assertEqual(target["sourceDigest"], expected["sourceDigest"])
            self.assertEqual([item["path"] for item in target["files"]], expected["paths"])


if __name__ == "__main__":
    unittest.main()
