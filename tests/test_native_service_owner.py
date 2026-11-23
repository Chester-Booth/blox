"""Exercise the production owner watcher against an isolated, restartable D-Bus."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("dbus-daemon") and shutil.which("dbus-monitor"),
                     "D-Bus tools are required")
class NativeServiceOwnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtCore import QCoreApplication
        from PySide6.QtQml import QQmlEngine
        cls.app = QCoreApplication.instance() or QCoreApplication([])
        cls.temporary = tempfile.TemporaryDirectory(prefix="blox-owner-bus-")
        cls.directory = Path(cls.temporary.name)
        cls.imports = cls.directory / "qml"
        result = subprocess.run([sys.executable, str(ROOT / "packaging/build_native_services.py"),
                                 "--output-import-path", str(cls.imports)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.address = f"unix:path={cls.directory / 'bus'}"
        cls.previous_address = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS")
        os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = cls.address
        cls.start_bus()
        cls.engine = QQmlEngine()
        cls.engine.addImportPath(str(cls.imports))

    @classmethod
    def start_bus(cls):
        cls.bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork",
                                    f"--address={cls.address}", "--print-address=1"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if not cls.bus.stdout.readline().strip().startswith(cls.address):
            raise RuntimeError("private D-Bus did not start")
        cls.monitor_file = (cls.directory / "monitor").open("w+")
        cls.monitor = subprocess.Popen(["dbus-monitor", "--address", cls.address,
                                       "type='method_call',interface='org.freedesktop.DBus',member='GetNameOwner'"],
                                      stdout=cls.monitor_file, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 3
        while not (cls.directory / "monitor").read_text() and time.monotonic() < deadline:
            if cls.monitor.poll() is not None:
                raise RuntimeError("private D-Bus monitor exited before subscribing")
            time.sleep(0.005)
        if not (cls.directory / "monitor").read_text():
            raise RuntimeError("private D-Bus monitor did not subscribe")

    @classmethod
    def stop_bus(cls):
        cls.monitor.terminate()
        cls.monitor.wait(timeout=3)
        cls.monitor_file.close()
        cls.bus.terminate()
        cls.bus.wait(timeout=3)
        cls.bus.stdout.close()
        cls.bus.stderr.close()

    @classmethod
    def tearDownClass(cls):
        import shiboken6
        shiboken6.delete(cls.engine)
        cls.stop_bus()
        if cls.previous_address is None:
            os.environ.pop("DBUS_SYSTEM_BUS_ADDRESS", None)
        else:
            os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = cls.previous_address
        cls.temporary.cleanup()

    def setUp(self):
        self.probes = []
        self.components = []
        self.connections = []
        self.names = [f"org.blox.Test{uuid.uuid4().hex}", f"org.blox.Test{uuid.uuid4().hex}"]

    def tearDown(self):
        import shiboken6
        from PySide6.QtDBus import QDBusConnection
        for probe in self.probes:
            shiboken6.delete(probe)
        for name, connection in self.connections:
            QDBusConnection.disconnectFromBus(name)
        self.spin(0.05)

    def spin(self, seconds=0.02):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            self.app.processEvents()
            time.sleep(0.002)

    def wait_for(self, predicate, timeout=3):
        until = time.monotonic() + timeout
        while not predicate() and time.monotonic() < until:
            self.spin(0.01)
        self.assertTrue(predicate(), "owner watcher did not reach expected state")

    def probe(self, primary=None, alternate="", enabled=True):
        from PySide6.QtCore import QUrl
        from PySide6.QtQml import QQmlComponent
        component = QQmlComponent(self.engine)
        self.components.append(component)
        component.setData(("import Blox.Services 1.0\nNativeServiceOwner { "
                           f"service: {json.dumps(primary or self.names[0])}; "
                           f"alternateService: {json.dumps(alternate)}; "
                           f"enabled: {enabled if isinstance(enabled, str) else str(enabled).lower()}; "
                           "property int discoveries: 0; onServiceFound: discoveries++; "
                           + " }").encode(), QUrl())
        probe = component.create()
        self.assertIsNotNone(probe, "\n".join(error.toString() for error in component.errors()))
        probe.setParent(self.engine)
        self.probes.append(probe)
        return probe

    def owner(self, service, replace=False):
        from PySide6.QtDBus import QDBusConnection, QDBusConnectionInterface
        name = "owner-" + uuid.uuid4().hex
        connection = QDBusConnection.connectToBus(self.address, name)
        self.assertTrue(connection.isConnected())
        result = connection.interface().registerService(
            service, QDBusConnectionInterface.ReplaceExistingService if replace
            else QDBusConnectionInterface.DontQueueService,
            QDBusConnectionInterface.AllowReplacement)
        self.assertTrue(result.isValid())
        self.connections.append((name, connection))
        return connection

    def calls(self):
        self.spin(0.04)
        return (self.directory / "monitor").read_text().count("member=GetNameOwner")

    def test_flaps_replacement_priority_and_shared_initial_queries(self):
        primary, alternate = self.names
        second_owner = self.owner(alternate)
        before = self.calls()
        first = self.probe(primary, alternate)
        second = self.probe(primary, alternate)
        self.wait_for(lambda: first.property("available") and second.property("available"))
        self.assertEqual(first.property("owner"), second_owner.baseService())
        self.assertEqual(self.calls() - before, 2)
        first.refresh()
        self.spin(0.08)
        self.assertEqual(first.property("discoveries"), 1)
        current = self.owner(primary)
        self.wait_for(lambda: first.property("owner") == current.baseService())
        replacement = self.owner(primary, replace=True)
        self.wait_for(lambda: first.property("owner") == replacement.baseService())
        self.assertEqual(first.property("discoveries"), 3)
        # Releasing the displaced connection prevents it queuing for reacquisition.
        from PySide6.QtDBus import QDBusConnection
        QDBusConnection.disconnectFromBus(current.name())
        replacement.interface().unregisterService(primary)
        self.wait_for(lambda: first.property("owner") == second_owner.baseService())
        second_owner.interface().unregisterService(alternate)
        self.wait_for(lambda: first.property("ready") and not first.property("available"))
        idle = self.calls()
        self.spin(1.2)
        self.assertEqual(self.calls(), idle, "connected watchers must not poll owners")

    def test_disable_cleans_up_and_latched_guard_stays_available(self):
        service = self.names[0]
        probe = self.probe(enabled=False)
        before = self.calls()
        owner = self.owner(service)
        self.spin(0.08)
        self.assertEqual(self.calls(), before)
        self.assertTrue(probe.property("available"))
        self.assertFalse(probe.property("ready"))
        probe.setProperty("enabled", True)
        self.wait_for(lambda: probe.property("owner") == owner.baseService())
        probe.setProperty("enabled", False)
        self.assertTrue(probe.property("available"))
        self.assertFalse(probe.property("ready"))
        self.assertEqual(probe.property("owner"), "")
        owner.interface().unregisterService(service)
        self.owner(service)
        probe.refresh()
        after = self.calls()
        self.spin(1.1)
        self.assertEqual(self.calls(), after)
        latched = self.probe(enabled="discoveries === 0")
        self.wait_for(lambda: latched.property("discoveries") == 1)
        self.assertFalse(latched.property("enabled"))
        self.assertTrue(latched.property("available"))

    def test_last_guard_can_disable_itself_during_real_owner_signal(self):
        probe = self.probe(enabled="discoveries === 0")
        self.wait_for(lambda: probe.property("ready") and not probe.property("available"))
        self.owner(self.names[0])
        self.wait_for(lambda: probe.property("discoveries") == 1)
        self.assertFalse(probe.property("enabled"))
        self.assertTrue(probe.property("available"))
        self.assertEqual(probe.property("owner"), "")
        idle = self.calls()
        self.spin(0.4)
        self.assertEqual(self.calls(), idle)

    def test_reconfiguration_discards_pending_answers_and_deduplicates_alias(self):
        primary, alternate = self.names
        self.owner(primary)
        target = self.owner(alternate)
        before = self.calls()
        probe = self.probe(primary, primary)
        probe.setProperty("service", alternate)
        probe.setProperty("alternateService", alternate)
        self.wait_for(lambda: probe.property("owner") == target.baseService())
        self.assertEqual(probe.property("discoveries"), 1)
        count = self.calls()
        self.assertGreater(count, before)
        probe.refresh()
        probe.refresh()
        self.spin(0.08)
        self.assertEqual(self.calls() - count, 1)
        self.assertEqual(probe.property("discoveries"), 1)

    def test_initial_query_timeout_invalidates_connection_then_recovers(self):
        first_owner = self.owner(self.names[0])
        first = self.probe()
        self.wait_for(lambda: first.property("owner") == first_owner.baseService())
        second_owner = self.owner(self.names[1])
        pending = self.probe(self.names[1], enabled=False)
        os.kill(self.bus.pid, signal.SIGSTOP)
        resume = threading.Timer(1.85, os.kill, args=(self.bus.pid, signal.SIGCONT))
        resume.start()
        try:
            started = time.monotonic()
            pending.setProperty("enabled", True)
            self.wait_for(lambda: pending.property("ready") and not pending.property("available"), timeout=2.3)
            self.assertLess(time.monotonic() - started, 2.3)
            self.assertFalse(first.property("available"))
            self.wait_for(lambda: pending.property("owner") == second_owner.baseService(), timeout=5)
            self.wait_for(lambda: first.property("owner") == first_owner.baseService())
            self.assertEqual(first.property("discoveries"), 2)
        finally:
            os.kill(self.bus.pid, signal.SIGCONT)
            resume.cancel()
            resume.join()

    def test_z_bus_disconnect_restart_and_disabled_reconnect_cleanup(self):
        service = self.names[0]
        owner = self.owner(service)
        probe = self.probe()
        self.wait_for(lambda: probe.property("owner") == owner.baseService())
        self.stop_bus()
        self.wait_for(lambda: probe.property("ready") and not probe.property("available"))
        self.spin(0.4)
        self.start_bus()
        replacement = self.owner(service)
        self.wait_for(lambda: probe.property("owner") == replacement.baseService(), timeout=7)
        self.assertEqual(probe.property("discoveries"), 2)
        probe.setProperty("enabled", False)
        self.stop_bus()
        self.spin(0.4)
        self.start_bus()
        self.owner(service)
        self.spin(0.7)
        self.assertEqual(self.calls(), 0)
        self.assertTrue(probe.property("available"))
        probe.setProperty("enabled", True)
        self.wait_for(lambda: probe.property("available") and probe.property("owner") != "")
        self.assertEqual(probe.property("discoveries"), 3)


if __name__ == "__main__":
    unittest.main()
