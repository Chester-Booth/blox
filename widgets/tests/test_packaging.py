"""Check widget package contents and launch imports without starting a shell."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / "packaging"))
import install as installer


class WidgetPackagingTests(unittest.TestCase):
    def test_source_package_contains_the_module_and_its_python_contract(self):
        files = {relative for _, relative in installer._iter_source_pairs(REPOSITORY)}
        required = {
            "widgets/catalogue.json",
            "widgets/schema/profile.schema.json",
            "widgets/lib/blox_widgets/model.py",
            "widgets/lib/blox_widgets/store.py",
            "widgets/lib/blox_widgets/cli.py",
            "widgets/lib/blox_widgets/broker.py",
            "widgets/qml/Blox/Widgets/qmldir",
            "widgets/qml/Blox/Widgets/WidgetHost.qml",
            "widgets/qml/Blox/Widgets/Native/ClockView.qml",
            "widgets/qml/Blox/Widgets/Providers/QuickshellBroker.qml",
        }
        self.assertTrue(required <= files, required - files)
        self.assertFalse(any("__pycache__" in relative for relative in files))

    def test_launcher_adds_sibling_import_for_source_and_installed_layouts(self):
        # Shadow Bash's exec builtin to inspect the final environment and arguments.
        # Neither the absolute Quickshell executable nor a desktop service runs.
        capture = 'exec() { printf "%s\\0" "$QML_IMPORT_PATH" "$BLOX_WIDGETS_ROOT" "${QS_ICON_THEME:-}" "$@"; exit 0; }; source "$1" --path "$2"'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for layout in ("source checkout", "installed prefix/share/blox"):
                for existing in (None, "/custom modules:/other/modules"):
                    with self.subTest(layout=layout, existing=existing):
                        package = root / layout
                        script = package / "shell/scripts/theme/start-quickshell.sh"
                        script.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(REPOSITORY / "shell/scripts/theme/start-quickshell.sh", script)
                        imports = package / "widgets/qml"
                        imports.mkdir(parents=True, exist_ok=True)
                        native_imports = package / "shell/native/qml"
                        native_module = native_imports / "Blox/Services"
                        native_module.mkdir(parents=True, exist_ok=True)
                        (native_module / "qmldir").write_text("module Blox.Services\nplugin bloxservicesplugin\n")
                        # exec is intercepted, so this fixture checks launch paths without loading a plugin.
                        (native_module / "libbloxservicesplugin.so").write_bytes(b"fixture plugin")
                        configured_shell = root / "config" / layout.replace("/", "-") / "blox"
                        configured_shell.parent.mkdir(parents=True, exist_ok=True)
                        if not configured_shell.is_symlink():
                            configured_shell.symlink_to(package / "shell", target_is_directory=True)
                        environment = dict(os.environ, XDG_STATE_HOME=str(root / "unused-state"), QS_ICON_THEME="fixture-icons",
                                           BLOX_WIDGETS_ROOT="/incorrect/inherited/path")
                        environment.pop("QML_IMPORT_PATH", None)
                        if existing is not None:
                            environment["QML_IMPORT_PATH"] = existing
                        result = subprocess.run(["bash", "-c", capture, "capture-launcher", str(configured_shell / "scripts/theme/start-quickshell.sh"), str(configured_shell)],
                                                env=environment, capture_output=True, check=True)
                        fields = result.stdout.decode().split("\0")
                        import_paths = fields[0].split(":")
                        self.assertEqual(Path(import_paths[0]).resolve(), native_imports.resolve())
                        self.assertEqual(Path(import_paths[1]).resolve(), imports.resolve())
                        self.assertEqual(import_paths[2:], existing.split(":") if existing else [])
                        self.assertEqual(fields[1:-1], [str((package / "widgets").resolve()), "fixture-icons", "/usr/bin/quickshell", "--path", str(configured_shell)])
                        self.assertFalse((root / "unused-state").exists())


if __name__ == "__main__":
    unittest.main()
