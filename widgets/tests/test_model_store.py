"""Fresh profile validation and isolated, transactional storage checks."""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from blox_widgets import (
    ConflictError, ProfileStore, ValidationError, catalogue, default_profile,
    default_widget, parse_profile, validate_profile, validate_settings,
)
from blox_widgets.store import profile_path


def profile(*widgets):
    return {"schemaVersion": 1, "widgets": list(widgets)}


class ModelTests(unittest.TestCase):
    def setUp(self):
        self.clock = default_widget("clock", "desk-clock")

    def test_catalogue_defaults_and_required_configuration(self):
        kinds = [entry["kind"] for entry in catalogue()["widgets"]]
        self.assertEqual(kinds[:8], ["clock", "music", "system", "network", "calendar", "notes", "files", "shortcuts"])
        for kind in kinds[:8]:
            with self.subTest(kind=kind):
                self.assertEqual(validate_profile(profile(default_widget(kind, kind)))["widgets"][0]["kind"], kind)
        for kind in ("weather", "terminal", "qml"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValidationError, "explicit configuration"):
                default_widget(kind, kind)
        self.assertEqual(default_widget("weather", "weather", {"latitude": 0, "longitude": 0})["settings"]["latitude"], 0)
        self.assertEqual(default_widget("terminal", "term", {"command": ["printf", "hello"]})["fullscreen"]["mode"], "resize")

    def test_validation_never_mutates_or_shares_document(self):
        original = profile(self.clock)
        before = copy.deepcopy(original)
        validated = validate_profile(original)
        validated["widgets"][0]["settings"]["showSeconds"] = True
        self.assertEqual(original, before)
        default_widget("clock", "other")["settings"]["showSeconds"] = True
        self.assertFalse(default_widget("clock", "fresh")["settings"]["showSeconds"])

    def test_presentation_defaults_are_independent_of_opacity(self):
        original = profile(self.clock)
        del original["widgets"][0]["appearance"]["presentation"]
        validated = validate_profile(original)
        self.assertEqual(validated["widgets"][0]["appearance"]["presentation"], "open")
        self.assertNotIn("presentation", original["widgets"][0]["appearance"])
        for presentation in ("open", "compact"):
            for opacity in (0, 0.35, 1):
                item = copy.deepcopy(self.clock)
                item["appearance"].update(presentation=presentation, backgroundOpacity=opacity)
                appearance = validate_profile(profile(item))["widgets"][0]["appearance"]
                self.assertEqual(appearance, item["appearance"])
        invalid = copy.deepcopy(self.clock)
        invalid["appearance"]["presentation"] = "rings"
        with self.assertRaisesRegex(ValidationError, "presentation"):
            validate_profile(profile(invalid))
        self.assertEqual(default_widget("system", "system")["settings"]["style"], "chart")

    def test_json_integer_semantics_and_empty_command_arguments(self):
        item = copy.deepcopy(self.clock)
        item["placement"]["width"] = 280.0
        canonical = validate_profile(profile(item))
        self.assertIs(type(canonical["widgets"][0]["placement"]["width"]), int)
        item["workspaces"]["ids"] = [1, 1.0]
        with self.assertRaisesRegex(ValidationError, "duplicate"):
            validate_profile(profile(item))
        terminal = default_widget("terminal", "term", {"command": ["printf", "%s", ""]})
        self.assertEqual(terminal["settings"]["command"][-1], "")
        for command in ([""], ["printf", "\0"]):
            with self.assertRaises(ValidationError):
                default_widget("terminal", "term", {"command": command})

    def test_terminal_complete_shared_settings_and_grid_boundaries(self):
        base = default_widget("terminal", "term", {"command": ["printf", "%s", ""]})["settings"]
        self.assertEqual(base["maxRuntimeSeconds"], 0)
        self.assertEqual(base["restartPolicy"], "never")
        self.assertEqual(validate_settings("terminal", dict(base, restartPolicy="always"))["restartPolicy"], "always")
        for policy in (None, True, "on-failure", "", "NEVER"):
            with self.subTest(policy=policy), self.assertRaises(ValidationError):
                validate_settings("terminal", dict(base, restartPolicy=policy))
        canonical = validate_settings("terminal", base)
        canonical["command"].append("independent")
        self.assertNotEqual(canonical, base)
        for columns, rows in ((2, 1), (240, 50), (120, 100)):
            settings = dict(base, columns=columns, rows=rows)
            self.assertEqual(validate_settings("terminal", settings), settings)
            default_widget("terminal", "term", settings)
        for columns, rows in ((1, 1), (241, 1), (2, 0), (2, 101), (240, 51)):
            with self.subTest(columns=columns, rows=rows), self.assertRaises(ValidationError):
                validate_settings("terminal", dict(base, columns=columns, rows=rows))
        for seconds in (0, 0.001, 86400):
            self.assertEqual(validate_settings("terminal", dict(base, maxRuntimeSeconds=seconds))["maxRuntimeSeconds"], seconds)
        for seconds in (-0.001, 86400.001, True, float("inf")):
            with self.subTest(seconds=seconds), self.assertRaises(ValidationError):
                validate_settings("terminal", dict(base, maxRuntimeSeconds=seconds))
        for field in base:
            incomplete = dict(base)
            del incomplete[field]
            with self.subTest(missing=field), self.assertRaisesRegex(ValidationError, "missing"):
                validate_settings("terminal", incomplete)

    def test_terminal_unicode_environment_and_transport_budgets(self):
        base = default_widget("terminal", "term", {"command": ["printf", "界" * 4096], "environment": {"NOTE": "é" * 2048}})["settings"]
        self.assertEqual(validate_settings("terminal", base), base)
        self.assertLess(len(json.dumps(base, ensure_ascii=True, separators=(",", ":")).encode("ascii")), 49152)
        environment = {f"VALUE_{index}": "" for index in range(128)}
        self.assertEqual(len(validate_settings("terminal", dict(base, environment=environment))["environment"]), 128)
        environment["EXCESS"] = ""
        for overrides in (
            {"environment": environment},
            {"environment": {"INVALID=KEY": ""}},
            {"environment": {"VALUE": "a" * 4097}},
            {"environment": {"VALUE": "\0"}},
            {"command": ["printf", "a" * 4097]},
            {"command": ["printf", "\ud800"]},
            {"workingDirectory": "relative/path"},
            {"workingDirectory": "/tmp/\0"},
        ):
            with self.subTest(overrides=str(overrides)[:100]), self.assertRaises(ValidationError):
                validate_settings("terminal", dict(base, **overrides))
        with self.assertRaisesRegex(ValidationError, "combined UTF-8"):
            validate_settings("terminal", dict(base, command=["printf"] + ["a" * 4096] * 8, environment={f"VALUE_{index}": "a" * 4096 for index in range(9)}))
        # Raw UTF-8 is small enough, but escaped ASCII JSON would exceed the broker line budget.
        with self.assertRaisesRegex(ValidationError, "encoded JSON"):
            validate_settings("terminal", dict(base, command=["printf", "界" * 4096, "界" * 4096], environment={}))

    def test_old_formats_and_unknown_fields_rejected(self):
        bad = [[], {"version": 1, "widgets": []}, {"schemaVersion": 0, "widgets": []}, {"schemaVersion": True, "widgets": []}]
        for field, value in (("command", "uptime"), ("profile", "clock"), ("opacity", 0.5)):
            item = copy.deepcopy(self.clock)
            item[field] = value
            bad.append(profile(item))
        item = copy.deepcopy(self.clock)
        item["settings"]["format24h"] = True
        bad.append(profile(item))
        for document in bad:
            with self.subTest(document=document), self.assertRaises(ValidationError):
                validate_profile(document)

    def test_duplicate_and_invalid_ids_rejected(self):
        with self.assertRaisesRegex(ValidationError, "duplicate id"):
            validate_profile(profile(self.clock, copy.deepcopy(self.clock)))
        for identifier in ("UPPER", "-clock", "clock--one", "a" * 65, "clock_", "clock\n"):
            with self.subTest(identifier=identifier), self.assertRaises(ValidationError):
                default_widget("clock", identifier)

    def test_workspace_exact_id_range_and_placement_bounds(self):
        self.clock["workspaces"] = {"mode": "include", "ids": [1, "1", "special:notes"], "ranges": [[-2, 5]]}
        validate_profile(profile(self.clock))
        for selectors in (
            {"mode": "include", "ids": [True], "ranges": []},
            {"mode": "include", "ids": [1.5], "ranges": []},
            {"mode": "include", "ids": [1000001], "ranges": []},
            {"mode": "include", "ids": [""], "ranges": []},
            {"mode": "include", "ids": [1, 1], "ranges": []},
            {"mode": "include", "ids": [], "ranges": [[5, 1]]},
            {"mode": "include", "ids": [], "ranges": [[1, 2, 3]]},
        ):
            self.clock["workspaces"] = selectors
            with self.subTest(selectors=selectors), self.assertRaises(ValidationError):
                validate_profile(profile(self.clock))
        self.clock["workspaces"] = {"mode": "include", "ids": [], "ranges": []}
        validate_profile(profile(self.clock))
        for field, value in (("width", 0), ("height", 16385), ("x", 100001), ("y", False)):
            item = copy.deepcopy(self.clock)
            item["placement"][field] = value
            with self.subTest(field=field), self.assertRaises(ValidationError):
                validate_profile(profile(item))

    def test_background_fullscreen_and_kind_specific_settings(self):
        for opacity in (-0.1, 1.01, True, float("nan"), float("inf")):
            item = copy.deepcopy(self.clock)
            item["appearance"]["backgroundOpacity"] = opacity
            with self.subTest(opacity=opacity), self.assertRaises(ValidationError):
                validate_profile(profile(item))
        self.clock["fullscreen"]["mode"] = "fit"
        with self.assertRaises(ValidationError):
            validate_profile(profile(self.clock))
        for kind, overrides in (("system", {"historySize": 241}), ("files", {"maxEntries": 257}), ("calendar", {"maxEvents": 257}), ("network", {"intervalSeconds": 0}), ("clock", {"timezone": "Invented/Nowhere"}), ("weather", {"latitude": 91, "longitude": 0})):
            with self.subTest(kind=kind), self.assertRaises(ValidationError):
                default_widget(kind, kind, overrides)
        self.assertEqual(default_widget("clock", "utc", {"timezone": "UTC"})["settings"]["timezone"], "UTC")

    def test_trusted_qml_bounded_settings_and_declared_layout(self):
        item = default_widget("qml", "custom", {"manifest": "trusted-chart", "layouts": ["fit"], "settings": {"axes": [1, True, None], "title": "Chart"}})
        self.assertEqual(item["fullscreen"]["mode"], "fit")
        item["fullscreen"]["mode"] = "crop"
        with self.assertRaisesRegex(ValidationError, "layout"):
            validate_profile(profile(item))
        nested = {"value": "text"}
        for _ in range(10):
            nested = {"value": nested}
        with self.assertRaises(ValidationError):
            default_widget("qml", "custom", {"manifest": "trusted-chart", "settings": nested})
        with self.assertRaises(ValidationError):
            default_widget("qml", "custom", {"manifest": "trusted-chart", "settings": {"value": object()}})
        with self.assertRaises(ValidationError):
            default_widget("qml", "custom", {"manifest": "trusted-chart", "source": "/tmp/arbitrary.qml"})

    def test_json_rejects_duplicate_keys_nonfinite_and_oversized_data(self):
        for text in ('{"schemaVersion":1,"schemaVersion":1,"widgets":[]}', '{"schemaVersion":NaN,"widgets":[]}', '{', ' ' * (4 * 1024 * 1024 + 1)):
            with self.subTest(text=text[:80]), self.assertRaises(ValidationError):
                parse_profile(text)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / "config" / "widgets.json"
        self.store = ProfileStore(self.path)
        self.document = profile(default_widget("notes", "notes", {"text": "A useful note"}))

    def test_missing_read_never_creates_files_or_directories(self):
        snapshot = self.store.read()
        self.assertEqual(snapshot.document, default_profile())
        self.assertIsNone(snapshot.digest)
        self.assertFalse(self.path.parent.exists())
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.root / "xdg")}):
            self.assertEqual(profile_path(), self.root / "xdg" / "blox" / "widgets.json")

    def test_roundtrip_export_and_replace_import(self):
        written = self.store.write(self.document, expected_digest=None)
        self.assertEqual(self.store.read(), written)
        self.assertEqual(self.store.export(), self.document)
        imported = ProfileStore(self.root / "portable.json").import_profile(self.store.export(), expected_digest=None, mode="replace")
        self.assertEqual(imported.document, self.document)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_stale_write_and_import_leave_committed_bytes_unchanged(self):
        first = self.store.write(self.document, expected_digest=None)
        changed = profile(default_widget("clock", "clock"))
        latest = self.store.write(changed, expected_digest=first.digest)
        before = self.path.read_bytes()
        for operation in (
            lambda: self.store.write(self.document, expected_digest=first.digest),
            lambda: self.store.import_profile(self.document, expected_digest=first.digest, mode="copy"),
            lambda: self.store.write(self.document, expected_digest=None),
        ):
            with self.assertRaises(ConflictError):
                operation()
            self.assertEqual(self.path.read_bytes(), before)
        # Even equivalent data edited by another writer counts as a conflicting revision.
        self.path.write_text(json.dumps(latest.document))
        with self.assertRaises(ConflictError):
            self.store.write(self.document, expected_digest=latest.digest)

    def test_invalid_input_cannot_create_or_mutate_store(self):
        bad = {"version": 0, "widgets": []}
        for operation in (
            lambda: self.store.write(bad, expected_digest=None),
            lambda: self.store.write(self.document, expected_digest="bad"),
            lambda: self.store.import_profile(bad, expected_digest=None, mode="replace"),
            lambda: self.store.import_profile(self.document, expected_digest=None, mode="merge"),
        ):
            with self.assertRaises(ValidationError):
                operation()
            self.assertFalse(self.path.parent.exists())

    def test_copy_import_collision_names_are_valid_and_deterministic(self):
        written = self.store.write(self.document, expected_digest=None)
        incoming = profile(default_widget("notes", "notes"), default_widget("notes", "notes-copy"))
        imported = self.store.import_profile(incoming, expected_digest=written.digest, mode="copy")
        self.assertEqual([item["id"] for item in imported.document["widgets"]], ["notes", "notes-copy-2", "notes-copy"])
        self.assertEqual(incoming["widgets"][0]["id"], "notes")
        long_id = "a" * 64
        other = ProfileStore(self.root / "long.json")
        initial = other.write(profile(default_widget("clock", long_id)), expected_digest=None)
        copied = other.import_profile(initial.document, expected_digest=initial.digest, mode="copy")
        self.assertEqual(len(copied.document["widgets"][1]["id"]), 64)
        validate_profile(copied.document)

    def test_atomic_replace_failure_preserves_original_and_cleans_temporary(self):
        written = self.store.write(self.document, expected_digest=None)
        before = self.path.read_bytes()
        with patch("blox_widgets.store.os.replace", side_effect=OSError("test interrupted replace")):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.store.write(default_profile(), expected_digest=written.digest)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.glob(".widgets.json.*")), [])

    def test_old_format_file_is_never_rewritten_on_read(self):
        self.path.parent.mkdir()
        original = b'{"version": 0, "presets": []}\n'
        self.path.write_bytes(original)
        with self.assertRaises(ValidationError):
            self.store.read()
        self.assertEqual(self.path.read_bytes(), original)

    def test_cli_json_roundtrip_and_conflict(self):
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / "lib"), XDG_CONFIG_HOME=str(self.root / "unused"))
        base = [sys.executable, "-m", "blox_widgets.cli", "--path", str(self.path)]

        def run(*args, document=None):
            result = subprocess.run([*base, *args], input=json.dumps(document) if document is not None else None, text=True, capture_output=True, env=env, check=False)
            return result.returncode, json.loads(result.stdout)

        code, read = run("read")
        self.assertEqual((code, read["digest"]), (0, None))
        code, written = run("write", "--expected-digest", "missing", document=self.document)
        self.assertEqual((code, written["profile"]), (0, self.document))
        code, exported = run("export")
        self.assertEqual((code, exported), (0, self.document))
        portable_file = self.root / "export.json"
        exported_process = subprocess.run([*base, "export"], text=True, capture_output=True, env=env, check=True)
        portable_file.write_text(exported_process.stdout)
        imported_path = self.root / "imported" / "widgets.json"
        imported_process = subprocess.run(
            [sys.executable, "-m", "blox_widgets.cli", "--path", str(imported_path), "import", "--expected-digest", "missing", "--mode", "replace", "--file", str(portable_file)],
            text=True, capture_output=True, env=env, check=True,
        )
        imported = json.loads(imported_process.stdout)
        self.assertEqual(imported["profile"], self.document)
        self.assertEqual(ProfileStore(imported_path).read().digest, imported["digest"])
        code, conflict = run("write", "--expected-digest", "missing", document=default_profile())
        self.assertEqual((code, conflict["error"]["type"]), (3, "conflict"))
        code, invalid = run("validate", document={"version": 0})
        self.assertEqual((code, invalid["error"]["type"]), (2, "validation"))
        self.assertFalse((self.root / "unused").exists())


if __name__ == "__main__":
    unittest.main()
