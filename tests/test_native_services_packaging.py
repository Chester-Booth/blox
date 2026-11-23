"""Native module release checks and lifecycle ownership without compiling fixtures."""

import json
import shutil
from pathlib import Path
import unittest
from unittest import mock

from tests.test_lifecycle import Fixture, fake_source, installer, snapshot_state
import build_native_services as native


def native_source(version="0.1.0", plugin=b"fixture plugin v1"):
    source = fake_source(version)
    cpp = source / "shell/native/services/service_owner.cpp"
    cpp.parent.mkdir(parents=True)
    cpp.write_text("// native fixture\n")
    for name in (*native.IMAGE_SOURCES, *native.EMOJI_SOURCES, *native.KEYBOARD_SOURCES, *native.PRIVACY_SOURCES, "image_cache_resolver.cpp"):
        (cpp.parent / name).write_text("// native fixture\n")
    bloxd_dir = source / "shell/native/bloxd/src"
    bloxd_dir.mkdir(parents=True)
    for name in native.BLOXD_SOURCES:
        (bloxd_dir / name).write_text("// rust fixture\n")
    module = source / "shell/native/qml/Blox/Services"
    module.mkdir(parents=True)
    (module / native.PLUGIN).write_bytes(plugin)
    (module / native.HELPER).write_bytes(plugin + b" helper")
    (module / native.HELPER).chmod(0o755)
    (module / native.DAEMON).write_bytes(plugin + b" bloxd")
    (module / native.DAEMON).chmod(0o755)
    (module / "qmldir").write_text(native.QMLDIR)
    (module / ".build.json").write_text(json.dumps({
        "format": 1,
        "sourceSha256": installer.sha256(cpp),
        "imageCacheSourceSha256": native.image_source_sha256(source),
        "emojiIndexSourceSha256": native.emoji_source_sha256(source),
        "keyboardBacklightSourceSha256": native.keyboard_source_sha256(source),
        "privacyMonitorSourceSha256": native.privacy_source_sha256(source),
        "bloxdSourceSha256": native.bloxd_source_sha256(source),
        "resolverSha256": installer.sha256(cpp.parent / "image_cache_resolver.cpp"),
        "buildScriptSha256": installer.sha256(source / "packaging/build_native_services.py"),
        "sha256": installer.sha256(module / native.PLUGIN),
        "imageCacheSha256": installer.sha256(module / native.HELPER),
        "bloxdSha256": installer.sha256(module / native.DAEMON),
    }))
    return source


def tree_state(root):
    return {str(path.relative_to(root)): ("directory" if path.is_dir() else path.read_bytes())
            for path in root.rglob("*")}


class NativeServicesPackagingTests(unittest.TestCase):
    def source(self, *args, **kwargs):
        source = native_source(*args, **kwargs)
        self.addCleanup(shutil.rmtree, source)
        return source

    def test_missing_or_stale_module_fails_before_creating_install_state(self):
        for changed in ("plugin-missing", "plugin", "source", "builder", "qmldir", "metadata", "helper-missing", "helper", "helper-mode", "image-source", "emoji-source", "keyboard-source", "keyboard-header", "keyboard-metadata", "resolver"):
            with self.subTest(changed=changed), Fixture() as roots:
                source = self.source()
                module = source / "shell/native/qml/Blox/Services"
                paths = {"plugin": module / native.PLUGIN,
                         "source": source / "shell/native/services/service_owner.cpp",
                         "builder": source / "packaging/build_native_services.py",
                         "qmldir": module / "qmldir", "metadata": module / ".build.json"}
                paths.update(helper=module / native.HELPER, **{"image-source": source / "shell/native/services/image_cache.cpp",
                             "emoji-source": source / "shell/native/services/emoji_index.cpp",
                             "keyboard-source": source / "shell/native/services/keyboard_backlight.cpp",
                             "keyboard-header": source / "shell/native/services/keyboard_backlight.h",
                             "resolver": source / "shell/native/services/image_cache_resolver.cpp"})
                if changed.endswith("-missing"):
                    paths[changed.removesuffix("-missing")].unlink()
                elif changed == "keyboard-metadata":
                    metadata = module / ".build.json"
                    record = json.loads(metadata.read_text())
                    record.pop("keyboardBacklightSourceSha256")
                    metadata.write_text(json.dumps(record))
                elif changed == "helper-mode":
                    paths["helper"].chmod(0o644)
                else:
                    paths[changed].write_text("changed")
                before = tree_state(Path(roots.home))
                for dry_run in (False, True):
                    with self.assertRaises(installer.LifecycleError) as error:
                        installer.install(roots, source_root=source, dry_run=dry_run)
                    self.assertEqual("unavailable", error.exception.code)
                    self.assertIn("make native-services", str(error.exception))
                    self.assertEqual(before, tree_state(Path(roots.home)))

    def test_production_wrapper_requires_module_when_native_source_directory_is_missing(self):
        with Fixture() as roots:
            source = self.source()
            wrapper = source / "shell/services/NativeServiceAvailability.qml"
            wrapper.parent.mkdir(parents=True)
            wrapper.write_text("import Blox.Services\n")
            shutil.rmtree(source / "shell/native/services")
            before = tree_state(roots.home)
            for dry_run in (False, True):
                with self.assertRaises(installer.LifecycleError) as error:
                    installer.install(roots, source_root=source, dry_run=dry_run)
                self.assertEqual("unavailable", error.exception.code)
                self.assertEqual(before, tree_state(roots.home))

    def test_valid_dry_run_reads_prebuilt_module_without_tools_or_writes(self):
        with Fixture() as roots:
            source = self.source()
            before_source = tree_state(source)
            before_home = tree_state(Path(roots.home))
            with mock.patch.object(native, "run", side_effect=AssertionError("build tool invoked")):
                result = installer.install(roots, source_root=source, dry_run=True)
            targets = {action["detail"] for action in result["plan"]["actions"]}
            self.assertIn("shell/native/qml/Blox/Services/" + native.PLUGIN, targets)
            self.assertEqual(before_source, tree_state(source))
            self.assertEqual(before_home, tree_state(Path(roots.home)))

    def test_manifest_owns_prebuilt_files_and_rollback_restores_binary(self):
        relative = "shell/native/qml/Blox/Services/" + native.PLUGIN
        with Fixture() as roots:
            first = self.source()
            second = self.source("0.2.0", b"fixture plugin v2")
            installer.install(roots, source_root=first)
            manifest = json.loads(roots.manifest.read_text())
            self.assertEqual(installer.sha256(first / relative), manifest["files"][relative]["sha256"])
            self.assertIn("shell/native/qml/Blox/Services/.build.json", manifest["files"])
            helper_relative = "shell/native/qml/Blox/Services/" + native.HELPER
            self.assertIn(helper_relative, manifest["files"])
            self.assertEqual([], installer.install(roots, source_root=first)["plan"]["actions"])
            installer.update(roots, source_root=second)
            self.assertEqual(b"fixture plugin v2", (roots.pkg_root / relative).read_bytes())
            self.assertEqual(b"fixture plugin v2 helper", (roots.pkg_root / helper_relative).read_bytes())
            installer.rollback(roots)
            self.assertEqual(b"fixture plugin v1", (roots.pkg_root / relative).read_bytes())
            self.assertEqual(b"fixture plugin v1 helper", (roots.pkg_root / helper_relative).read_bytes())
            self.assertEqual(manifest, json.loads(roots.manifest.read_text()))

    def test_update_rejects_stale_module_before_snapshot_or_lock_changes(self):
        with Fixture() as roots:
            installer.install(roots, source_root=self.source())
            source = self.source("0.2.0")
            (source / "shell/native/services/service_owner.cpp").write_text("// edited\n")
            before = snapshot_state(roots)
            state_before = tree_state(roots.state)
            for dry_run in (False, True):
                with self.assertRaises(installer.LifecycleError):
                    installer.update(roots, source_root=source, dry_run=dry_run)
                self.assertEqual(before, snapshot_state(roots))
                self.assertEqual(state_before, tree_state(roots.state))


if __name__ == "__main__":
    unittest.main()
