"""Run the production native watcher on private sysfs fixtures and a private D-Bus."""

import fcntl
import hashlib
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "shell/native/services"


class KeyboardBacklightWatcherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="blox-keyboard-tests-", dir="/tmp")
        cls.directory = Path(cls.temporary.name)
        cls.imports = ROOT / "shell/native/qml"
        cls.run_checked([sys.executable, "-B", str(ROOT / "packaging/build_native_services.py"),
                         "--output-import-path", str(cls.imports)])
        sources = (
            SOURCE / "keyboard_backlight.h",
            SOURCE / "keyboard_backlight.cpp",
            ROOT / "tests/native/keyboard_backlight_test.cpp",
        )
        digest = hashlib.sha256()
        for path in sources:
            digest.update(path.read_bytes())
        cache_dir = Path.home() / ".cache/blox-test-cache"
        cache_dir.mkdir(parents=True, exist_ok=True)
        cls.binary = cache_dir / f"keyboard-tests-{digest.hexdigest()[:16]}"
        if not cls.binary.is_file():
            packages = ["Qt6Test", "Qt6Qml", "Qt6DBus"]
            flags = shlex.split(cls.run_checked(["pkg-config", "--cflags", *packages]))
            libraries = shlex.split(cls.run_checked(["pkg-config", "--libs", *packages]))
            moc = str(Path(cls.run_checked(["pkg-config", "--variable=libexecdir", "Qt6Core"]).strip()) / "moc")
            for source, output in ((SOURCE / "keyboard_backlight.h", "moc_keyboard_backlight.cpp"),
                                   (SOURCE / "keyboard_backlight.cpp", "keyboard_backlight.moc"),
                                   (ROOT / "tests/native/keyboard_backlight_test.cpp", "keyboard_backlight_test.moc")):
                cls.run_checked([moc, *flags, str(source), "-o", str(cls.directory / output)])
            staged = cache_dir / f".keyboard-tests-{os.getpid()}"
            cls.run_checked([*shlex.split(os.environ.get("CXX", "c++")), "-std=c++17", "-O2", "-fPIC",
                             *flags, "-I", str(SOURCE), "-I", str(cls.directory),
                             str(SOURCE / "keyboard_backlight.cpp"), str(cls.directory / "moc_keyboard_backlight.cpp"),
                             str(ROOT / "tests/native/keyboard_backlight_test.cpp"), "-o", str(staged), *libraries])
            staged.replace(cls.binary)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    @staticmethod
    def run_checked(command, **kwargs):
        result = subprocess.run(command, capture_output=True, text=True, timeout=90, **kwargs)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout

    def test_native_sysfs_signals_lock_reload_and_async_lifetimes(self):
        output = self.run_checked([str(self.binary)], env={**os.environ, "TMPDIR": "/tmp"})
        self.assertIn("0 failed", output)
        print(output, end="")

    def check_shutdown(self, sig):
        # Keep this parent alive, as Quickshell does during a QML reload.
        with tempfile.TemporaryDirectory(dir=self.directory) as temporary:
            root = Path(temporary)
            device = root / "leds/test::kbd_backlight"
            device.mkdir(parents=True)
            (device / "brightness").write_text("1\n")
            (device / "max_brightness").write_text("3\n")
            watcher = subprocess.Popen([str(self.binary), "--hold", str(root)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([watcher.stdout], [], [], 3)[0], "Watcher did not start")
                self.assertEqual(watcher.stdout.readline(), b"ready\n")
                with (root / "runtime/keyboard-backlight.lock").open("w") as lock:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    watcher.send_signal(sig)
                    watcher.wait(timeout=3)
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(watcher.returncode, -sig)
            finally:
                if watcher.poll() is None:
                    watcher.kill()
                watcher.communicate(timeout=3)

    def test_termination_releases_lock(self):
        self.check_shutdown(signal.SIGTERM)

    def test_forced_death_releases_lock(self):
        self.check_shutdown(signal.SIGKILL)

    def test_production_qml_keyboard_conversion(self):
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QML_DISABLE_DISK_CACHE="1",
                   XDG_RUNTIME_DIR=str(self.directory), KEYBOARD_BRIGHTNESS_DEVICE="invalid/device",
                   DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={self.directory}/no-system-bus",
                   DBUS_SESSION_BUS_ADDRESS=f"unix:path={self.directory}/no-session-bus")
        self.run_checked([sys.executable, "-B", __file__, "qml-worker", str(self.imports)], env=env)


def qml_worker(imports):
    import shiboken6
    from PySide6.QtCore import QUrl
    from PySide6.QtGui import QGuiApplication
    from PySide6.QtQml import QQmlComponent, QQmlEngine
    app = QGuiApplication([])
    engine = QQmlEngine()
    engine.addImportPath(str(ROOT / "shell"))
    engine.addImportPath(str(ROOT / "tests/qml/imports"))
    engine.addImportPath(imports)
    component = QQmlComponent(engine, QUrl.fromLocalFile(str(ROOT / "shell/modules/OsdController.qml")))
    root = component.create()
    assert root, [error.toString() for error in component.errors()]
    watcher = next(child for child in root.children()
                   if child.metaObject().className().endswith("KeyboardBacklightWatcher"))
    assert watcher.property("status") == "invalid-device"
    assert not root.property("showing")
    for value, maximum, percent, segments in ((1, 3, 33, 1), (2, 3, 67, 2), (4, 8, 50, 2),
                                               (0, 3, 0, 0), (3, 3, 100, 3)):
        watcher.levelChanged.emit(value, maximum)
        app.processEvents()
        assert root.property("showing")
        assert root.property("label") == "Keyboard Backlight"
        assert root.property("value") == percent
        assert root.property("activeSegments") == segments
    shiboken6.delete(root)
    shiboken6.delete(engine)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "qml-worker":
        qml_worker(sys.argv[2])
    else:
        unittest.main()
