"""Focused native observations using owned sources, never live network services."""
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture
from unittest.mock import patch

from blox_widgets.broker import Broker, OutputQueue, ReadWorker, decode_request
from blox_widgets.providers import CalendarProvider, ClockProvider, FilesProvider, NetworkProvider, SystemProvider, WeatherProvider


class FileEvent:
    """A kill-safe handshake for owned child fixtures, with no shared lock."""
    def __init__(self, path):
        self.path = path

    def set(self):
        self.path.touch()

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.path.exists():
                return True
            time.sleep(.002)
        return self.path.exists()


class ProvidersTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def put(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_system_two_samples_and_gap(self):
        self.put('stat', 'cpu 100 0 50 850 0 0 0 0\n')
        self.put('meminfo', 'MemTotal: 1000 kB\nMemAvailable: 400 kB\n')
        self.put('uptime', '123.5 1\n')
        self.put('cpuinfo', 'cpu MHz : 2400\n')
        provider = SystemProvider({}, proc_root=self.root, sys_root=self.root / 'sys')
        self.assertIsNone(provider.sample(1)['cpuPercent'])
        self.put('stat', 'cpu 120 0 60 920 0 0 0 0\n')
        value = provider.sample(2)
        self.assertEqual(value['cpuPercent'], 30)
        self.assertEqual(value['memoryUsedBytes'], 600 * 1024)
        self.assertEqual(value['cpuFrequencyGHz'], 2.4)
        self.assertIsNone(provider.sample(20)['cpuPercent'])
        self.assertIsNone(provider.history[-1]['cpuPercent'])

    def test_network_first_reset_and_gap_are_null(self):
        def write(rx, tx):
            self.put('net/dev', f'header\nheader\n eth0: {rx} 0 0 0 0 0 0 0 {tx} 0 0 0 0 0 0 0\n')
        write(100, 200)
        provider = NetworkProvider({}, proc_root=self.root)
        self.assertIsNone(provider.sample(1)['rxBytesPerSecond'])
        write(300, 500)
        self.assertEqual(provider.sample(3)['rxBytesPerSecond'], 100)
        write(10, 10)
        self.assertIsNone(provider.sample(4)['rxBytesPerSecond'])
        write(100, 100)
        self.assertIsNone(provider.sample(20)['rxBytesPerSecond'])

    def test_clock_real_iana_and_invalid_zone(self):
        tokyo = ClockProvider({'timezone': 'Asia/Tokyo', 'showSeconds': False}).sample(0)
        self.assertTrue(tokyo['iso'].endswith('+09:00'))
        self.assertEqual(tokyo['date'], tokyo['iso'][:10])
        self.assertEqual(len(tokyo['text']), 5)
        with self.assertRaises((KeyError, ValueError)):
            ClockProvider({'timezone': 'Definitely/Absent'})

    def test_calendar_readonly_existing_store_and_missing_does_not_create(self):
        path = self.root / 'calendar.sqlite3'
        provider = CalendarProvider({'path': str(path)})
        with self.assertRaises(sqlite3.OperationalError):
            provider.sample(0)
        self.assertFalse(path.exists())
        db = sqlite3.connect(path)
        db.executescript('''CREATE TABLE meta(key TEXT,value TEXT);
            INSERT INTO meta VALUES ('revision','2');
            CREATE TABLE calendars(id TEXT,summary TEXT,background TEXT,selected INTEGER);
            INSERT INTO calendars VALUES ('c','Personal','#fff',1);
            CREATE TABLE events(event_id TEXT,title TEXT,start_value TEXT,end_value TEXT,start_kind TEXT,
                fetched_at_ms INTEGER,calendar_id TEXT,status TEXT);
            INSERT INTO events VALUES ('1','Future','2099-01-01','2099-01-02','all_day',123,'c','confirmed');''')
        db.close()
        before = path.read_bytes()
        snapshot = provider.sample(0)
        self.assertEqual(snapshot['sourceRevision'], '2')
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['calendar.sqlite3'])

    def test_files_bounded_and_missing_config(self):
        for number in range(10):
            self.put(f'{number}.txt', 'data')
        value = FilesProvider({'directory': str(self.root), 'maxEntries': 3}).sample(0)
        self.assertEqual(len(value['entries']), 3)
        self.assertTrue(value['truncated'])
        with self.assertRaises(ValueError):
            FilesProvider({'directory': ''})

    def test_weather_requires_location_and_uses_bounded_injected_transport(self):
        calls = []
        class Response(io.BytesIO):
            pass
        def transport(request, timeout):
            calls.append((request.full_url, timeout))
            return Response(json.dumps({'current': {'temperature_2m': 14, 'weather_code': 3,
                'is_day': 1, 'wind_speed_10m': 7, 'time': '2026-10-18T12:00'}}).encode())
        with self.assertRaises(ValueError):
            WeatherProvider({})
        value = WeatherProvider({'latitude': 51, 'longitude': 0}, http_open=transport).sample(0)
        self.assertEqual(value['temperatureC'], 14)
        self.assertIn('current=temperature_2m', calls[0][0])
        self.assertEqual(calls[0][1], 5)


class BrokerTest(unittest.TestCase):
    def setUp(self):
        self.output, self.providers = [], []
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.event_sequence = 0
        self.now = 1
        class Sample:
            interval = 1
            def __init__(inner):
                inner.count, inner.closed = 0, False
            def sample(inner, now):
                inner.count += 1
                return {'count': inner.count}
            def close(inner):
                inner.closed = True
        def factory(*args, **kwargs):
            value = Sample()
            self.providers.append(value)
            return value
        self.broker = Broker(self.output.append, factory=factory, clock=lambda: self.now)

    def event(self):
        self.event_sequence += 1
        return FileEvent(Path(self.temp.name) / str(self.event_sequence))

    def tearDown(self):
        self.broker.close()

    def subscribe(self, consumer, generation=1):
        self.broker.handle({'requestId': consumer, 'op': 'subscribe', 'consumerId': consumer,
            'provider': 'system', 'options': {}, 'generation': generation})

    def test_shared_samples_fresh_reveal_and_zero_consumers(self):
        self.subscribe('a')
        self.subscribe('b', 2)
        self.assertEqual(len(self.providers), 1)
        self.broker.tick()
        self.assertEqual(self.providers[0].count, 1)
        ready = [x for x in self.output if x.get('snapshot', {}).get('state') == 'ready']
        self.assertEqual([x['snapshot']['generation'] for x in ready], [1, 2])
        self.broker.unsubscribe('a')
        self.broker.unsubscribe('b')
        self.now += 100
        self.broker.tick()
        self.assertEqual(self.providers[0].count, 1)
        self.assertIsNone(self.broker.wait_seconds())
        self.subscribe('a', 3)
        self.assertEqual(len(self.providers), 2)
        self.broker.tick()
        self.assertEqual(self.output[-1]['snapshot']['generation'], 3)

    def test_wait_uses_next_provider_deadline(self):
        self.subscribe('a')
        self.providers[0].interval = 60
        self.broker.tick()
        self.assertEqual(self.broker.wait_seconds(), 60)
        self.now += 59
        self.assertEqual(self.broker.wait_seconds(), 1)
        self.now += 1
        self.assertEqual(self.broker.wait_seconds(), 0)
        self.broker.tick()
        self.assertEqual(self.providers[0].count, 2)

    def test_late_worker_completion_cannot_reveal_cancelled_generation(self):
        started, release = self.event(), self.event()
        provider = self.providers
        class Slow:
            interval = 1
            asynchronous = True
            def sample(inner, now):
                started.set()
                release.wait(2)
                return {'late': True}
            def close(inner): pass
        self.broker.factory = lambda *args, **kwargs: Slow()
        try:
            self.subscribe('a')
            self.broker.tick()
            self.assertTrue(started.wait(1))
            self.assertLessEqual(self.broker.wait_seconds(), .05)
            self.broker.unsubscribe('a')
            release.set()
            time.sleep(.02)
            self.broker.tick()
            self.assertFalse(any(x.get('snapshot', {}).get('state') == 'ready' for x in self.output))
        finally:
            release.set()

    def test_new_consumer_waits_for_observation_started_after_subscription(self):
        started, release = self.event(), self.event()
        class Slow:
            interval = 1
            asynchronous = True
            def sample(inner, now):
                started.set()
                release.wait(2)
                return {'fresh': True}
            def close(inner): pass
        self.broker.factory = lambda *args, **kwargs: Slow()
        try:
            self.subscribe('a')
            self.broker.tick()
            self.assertTrue(started.wait(1))
            self.subscribe('b')
            release.set()
            time.sleep(.02)
            self.broker.tick()
            ready = [x['consumerId'] for x in self.output if x.get('snapshot', {}).get('state') == 'ready']
            self.assertEqual(ready, ['a'])
            time.sleep(.02)
            self.broker.tick()
            self.assertTrue(any(x.get('consumerId') == 'b' and x['snapshot']['state'] == 'ready' for x in self.output if 'snapshot' in x))
        finally:
            release.set()

    def test_actual_terminal_broker_observes_and_cancels_owned_process(self):
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)
        from blox_widgets.terminal import TerminalSession
        sessions, output = [], []
        def factory(name, options, generation):
            session = TerminalSession(options, generation)
            sessions.append(session)
            return session
        broker = Broker(output.append, factory=factory)
        try:
            broker.handle({'requestId': 1, 'op': 'subscribe', 'consumerId': 'terminal',
                'provider': 'terminal', 'options': {'command': [sys.executable, '-c',
                    'import time; print("owned terminal", flush=True); time.sleep(10)'],
                    'workingDirectory': '', 'environment': {}, 'columns': 40, 'rows': 4,
                    'maxRuntimeSeconds': 0, 'restartPolicy': 'never'}, 'generation': 7})
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and not any(x.get('snapshot', {}).get('state') == 'ready' for x in output):
                for key, _ in broker.selector.select(0):
                    broker.descriptor_ready(key.fd, key.data)
                broker.tick()
                time.sleep(.01)
            ready = [x['snapshot'] for x in output if x.get('snapshot', {}).get('state') == 'ready']
            self.assertTrue(ready)
            self.assertIsNone(broker.wait_seconds())
            self.assertEqual(ready[0]['generation'], 7)
            self.assertIn('owned terminal', json.dumps(ready[0]['value']))
            broker.unsubscribe('terminal')
            self.assertTrue(sessions[0].closed)
            self.assertEqual(broker.groups, {})
            self.assertIsNone(broker.wait_seconds())
        finally:
            broker.close()

    def test_blocked_filesystem_workers_are_killed_and_slots_recover(self):
        fifo = Path(self.temp.name) / 'blocked.fifo'
        os.mkfifo(fifo)
        class Blocked:
            interval = 60
            asynchronous = True
            def sample(inner, now):
                with fifo.open('rb') as stream:
                    stream.read(1)
            def close(inner): pass
        class Fast:
            interval = 60
            asynchronous = True
            def sample(inner, now): return {'recovered': True}
            def close(inner): pass
        broker = Broker(self.output.append, factory=lambda *args, **kwargs: Blocked(), worker_timeout=.05)
        try:
            for number in range(4):
                broker.handle({'requestId': number, 'op': 'subscribe', 'consumerId': str(number),
                    'provider': 'files', 'options': {'slot': number}, 'generation': 1})
            broker.tick()
            workers = list(broker.pending)
            self.assertEqual(len(workers), 4)
            time.sleep(.06)
            broker.tick()
            self.assertTrue(all(worker.exited for worker in workers))
            self.assertTrue(any(x.get('snapshot', {}).get('state') == 'unavailable' for x in self.output))
            broker.factory = lambda *args, **kwargs: Fast()
            broker.handle({'requestId': 5, 'op': 'subscribe', 'consumerId': 'fresh',
                'provider': 'calendar', 'options': {}, 'generation': 2})
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline and not any(x.get('consumerId') == 'fresh' and x.get('snapshot', {}).get('state') == 'ready' for x in self.output):
                broker.tick()
                time.sleep(.005)
            self.assertTrue(any(x.get('consumerId') == 'fresh' and x.get('snapshot', {}).get('state') == 'ready' for x in self.output))
        finally:
            started = time.monotonic()
            broker.close()
            self.assertLess(time.monotonic() - started, .7)
            self.assertFalse(broker.pending)

    def test_waiting_group_precedes_repeated_timed_out_retries(self):
        worker_patch = patch('blox_widgets.broker.ReadWorker', wraps=ReadWorker)
        worker_factory = worker_patch.start()
        self.addCleanup(worker_patch.stop)
        fifo = Path(self.temp.name) / 'retry.fifo'
        os.mkfifo(fifo)
        class Blocked:
            interval = 10
            asynchronous = True
            def sample(inner, now):
                with fifo.open('rb') as stream:
                    stream.read(1)
            def close(inner): pass
        class Fast:
            interval = 10
            asynchronous = True
            def sample(inner, now): return {'healthy': True}
            def close(inner): pass
        broker = Broker(self.output.append, factory=lambda name, options, **kwargs:
                        Fast() if options['slot'] == 4 else Blocked(), clock=lambda: self.now)
        self.addCleanup(broker.close)
        for number in range(5):
            if number == 4:
                # New demand must also precede retries of already-running groups.
                broker.tick()
            broker.handle({'requestId': number, 'op': 'subscribe', 'consumerId': str(number),
                'provider': 'files', 'options': {'slot': number}, 'generation': 1})
        groups = {consumer: broker.groups[key] for consumer, key in broker.consumers.items()}
        broker.tick()
        self.assertEqual(len(broker.pending), 4)
        self.assertEqual(groups['4'].sequence, 0)
        self.assertGreater(broker.wait_seconds(), 0)
        self.assertLessEqual(broker.wait_seconds(), .05)

        for round_number in range(1, 5):
            workers = list(broker.pending)
            self.now += 14.05
            broker.tick()
            self.assertTrue(all(worker.exited for worker in workers))
            broker.tick()
            # The healthy fifth group gets the first reclaimed slot, before retries.
            self.assertEqual(groups['4'].sequence, round_number)
            self.assertEqual(groups['4'].started, self.now)
            self.assertIs(worker_factory.call_args_list[4 + 5 * (round_number - 1)].args[0], groups['4'].provider)
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                broker.tick()
                self.assertLessEqual(len(broker.pending), 4)
                self.assertGreater(broker.wait_seconds(), 0)
                ready = [x for x in self.output if x.get('consumerId') == '4'
                         and x.get('snapshot', {}).get('state') == 'ready']
                if len(ready) == round_number and all(groups[str(i)].sequence == round_number + 1 for i in range(4)):
                    break
                time.sleep(.002)
            self.assertEqual(len(ready), round_number)
            self.assertTrue(all(groups[str(i)].sequence == round_number + 1 for i in range(4)))
            self.assertEqual(len(broker.pending), 4)
            self.assertEqual(len([x for x in self.output if x.get('snapshot', {}).get('state') == 'unavailable']),
                             4 * round_number)

        attempts = [group.sequence for group in groups.values()]
        broker.close()
        self.assertFalse(broker.pending)
        self.now += 100
        broker.tick()
        self.assertEqual([group.sequence for group in groups.values()], attempts)
        self.assertIsNone(broker.wait_seconds())

    def test_subscription_churn_cannot_overtake_waiter_or_unreaped_workers(self):
        workers = []
        class Worker:
            def __init__(inner, provider, now):
                inner.reaped = False
                workers.append(inner)
                self.assertLessEqual(sum(not worker.reaped for worker in workers), 4)
            def done(inner): return inner.reaped
            def cancel(inner): pass  # Cancellation cannot release a slot before reaping.
            def result(inner): return {'healthy': True}
        class Sample:
            interval = 10
            asynchronous = True
            def close(inner): pass
        with patch('blox_widgets.broker.ReadWorker', Worker):
            broker = Broker(self.output.append, factory=lambda *args, **kwargs: Sample(), clock=lambda: self.now)
            self.addCleanup(broker.close)
            def subscribe(consumer):
                broker.handle({'requestId': consumer, 'op': 'subscribe', 'consumerId': consumer,
                    'provider': 'files', 'options': {'slot': consumer}, 'generation': 1})
            subscribe('established')
            broker.tick()
            group = next(iter(broker.groups.values()))
            consumers = [f'fresh-{number}' for number in range(4)]
            for consumer in consumers:
                subscribe(consumer)
            group.future.reaped = True
            self.now += 14.05
            broker.tick()
            self.assertEqual(len(broker.pending), 4)

            for round_number in range(1, 5):
                old_workers = list(broker.pending)
                for consumer in consumers:
                    broker.unsubscribe(consumer)
                consumers = [f'fresh-{round_number}-{number}' for number in range(4)]
                for consumer in consumers:
                    subscribe(consumer)
                attempts = len(workers)
                broker.tick()
                self.assertEqual(len(workers), attempts)
                self.assertEqual(broker.wait_seconds(), .05)
                for worker in old_workers:
                    worker.reaped = True
                broker.tick()
                self.assertEqual(group.sequence, round_number + 1)
                self.assertIs(group.future, workers[attempts])
                group.future.reaped = True
                broker.tick()
                self.assertEqual(len(broker.pending), 4)
                self.now += 14.05

            for worker in workers:
                worker.reaped = True
            broker.close()
            self.assertFalse(broker.pending)
            self.assertIsNone(broker.wait_seconds())

    def test_unsubscribe_reaps_blocked_read_without_waiting_for_io(self):
        fifo = Path(self.temp.name) / 'cancel.fifo'
        os.mkfifo(fifo)
        class Blocked:
            interval = 60
            asynchronous = True
            def sample(inner, now):
                with fifo.open('rb') as stream:
                    stream.read(1)
            def close(inner): pass
        broker = Broker(self.output.append, factory=lambda *args, **kwargs: Blocked())
        try:
            broker.handle({'requestId': 1, 'op': 'subscribe', 'consumerId': 'blocked',
                'provider': 'files', 'options': {}, 'generation': 1})
            broker.tick()
            worker = next(iter(broker.pending))
            started = time.monotonic()
            broker.unsubscribe('blocked')
            self.assertLess(time.monotonic() - started, .3)
            self.assertTrue(worker.exited)
            self.assertIsNone(broker.wait_seconds())
        finally:
            broker.close()

    def test_large_shared_calendar_fanout_drains_without_provider_failure(self):
        output = OutputQueue()
        large = 'x' * 4096
        value = {'events': [{'id': str(i), 'title': large, 'calendar': large} for i in range(100)]}
        class Calendar:
            interval = 30
            def sample(inner, now): return value
            def close(inner): pass
        broker = Broker(output.emit, factory=lambda *args, **kwargs: Calendar(), cancel_output=output.cancel_consumer)
        try:
            for number in range(32):
                broker.handle({'requestId': number, 'op': 'subscribe', 'consumerId': str(number),
                    'provider': 'calendar', 'options': {}, 'generation': 1})
            broker.tick()
            self.assertEqual(len(output.snapshots), 32)
            self.assertTrue(all(record['snapshot']['value'] is value for record in output.snapshots.values()))
            self.assertEqual(output.active, b'')
            ready, buffer = set(), bytearray()
            while output:
                chunk = output.chunk()
                self.assertLessEqual(len(chunk), 65536)
                buffer.extend(chunk)
                output.advance(len(chunk))
                while b'\n' in buffer:
                    line, _, rest = buffer.partition(b'\n')
                    buffer[:] = rest
                    response = json.loads(line)
                    if 'snapshot' in response:
                        self.assertEqual(response['snapshot']['state'], 'ready')
                        ready.add(response['consumerId'])
            self.assertEqual(len(ready), 32)
            self.assertFalse(buffer)
        finally:
            broker.close()

    def test_unconfigured_source_error_is_scoped_to_its_generation(self):
        output = []
        broker = Broker(output.append)
        try:
            broker.handle({'requestId': 1, 'op': 'subscribe', 'consumerId': 'calendar',
                'provider': 'calendar', 'generation': 8,
                'options': {'style': 'month', 'path': '', 'daysAhead': 31, 'maxEvents': 100}})
            self.assertEqual(output[-1]['consumerId'], 'calendar')
            self.assertEqual(output[-1]['generation'], 8)
            self.assertEqual(output[-1]['error']['code'], 'invalid_request')
        finally:
            broker.close()

    def test_protocol_bounds_duplicate_keys_and_unknown_fields(self):
        for text in [b'{"op":"a","op":"b"}', b'{"x":NaN}', b'x' * 65537]:
            with self.assertRaises(ValueError): decode_request(text)
        self.broker.handle({'requestId': 'bad', 'op': 'subscribe', 'consumerId': 'a',
            'provider': 'system', 'options': {}, 'generation': True})
        self.assertEqual(self.output[-1]['error']['code'], 'invalid_request')

    def test_jsonl_owned_subprocess_shutdown(self):
        environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[1] / 'lib'))
        process = subprocess.Popen([sys.executable, '-m', 'blox_widgets.broker'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        try:
            process.stdin.write(b'{"requestId":1,"op":"subscribe","consumerId":"clock","provider":"clock","options":{"style":"digital","timezone":"UTC","format":"24h","showSeconds":true},"generation":2}\n')
            process.stdin.flush()
            ready = False
            for _ in range(3):
                self.assertTrue(select.select([process.stdout], [], [], 2)[0])
                message = json.loads(process.stdout.readline())
                if message.get('snapshot', {}).get('state') == 'ready':
                    self.assertEqual(message['snapshot']['generation'], 2)
                    ready = True
                    break
            self.assertTrue(ready)
            process.stdin.write(b'{"requestId":2,"op":"shutdown"}\n')
            process.stdin.flush()
            self.assertEqual(process.wait(3), 0)
        finally:
            if process.poll() is None: process.kill()
            process.communicate(timeout=3)


@unittest.skipUnless(shutil.which('quickshell'), 'Quickshell is unavailable')
class AdapterLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = Path(__file__).resolve().parents[2]

    def run_qml(self, source, timeout=7, workdir=None):
        run_root = workdir or self.root
        run_root.mkdir(parents=True, exist_ok=True)
        fixture = run_root / 'fixture.qml'
        source = source.replace(json.dumps(str(self.repo / 'widgets/lib')), json.dumps(self.supervision.pythonpath(str(self.repo / 'widgets/lib'))))
        fixture.write_text(source)
        environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
            QT_QPA_PLATFORMTHEME='generic', QT_STYLE_OVERRIDE='Fusion',
            DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent', DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent',
            HOME=str(run_root), XDG_CONFIG_HOME=str(run_root), XDG_DATA_HOME=str(run_root),
            XDG_CACHE_HOME=str(run_root), XDG_RUNTIME_DIR=str(run_root),
            QML_IMPORT_PATH=os.pathsep.join(filter(None,[os.environ.get('QML_IMPORT_PATH'),str(self.repo / 'widgets/qml')])), BLOX_DATA_DIR=str(self.repo / 'themes'))
        for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE'):
            environment.pop(name, None)
        result = subprocess.run(['quickshell', '--no-color', '--path', str(fixture)],
            env=environment, capture_output=True, text=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_zero_and_music_only_consumers_do_not_start_broker(self):
        marker = self.root / 'unexpected-start'
        command = json.dumps([sys.executable, '-c', f'from pathlib import Path; Path({str(marker)!r}).touch()'])
        self.run_qml('''import QtQuick
import Quickshell
import Blox.Widgets.Providers 1.0
Scope {
    NativeProvider { id: empty; enabled: true; enableNativeMusic: false; brokerCommand: COMMAND }
    NativeProvider { id: music; enabled: true; enableNativeMusic: false; brokerCommand: COMMAND }
    Component.onCompleted: music.subscribe("music", "music", {style:"compact",player:"",showArtwork:false}, 1)
    Timer { interval: 150; running: true; onTriggered: Qt.exit(0) }
}'''.replace('COMMAND', command))
        self.assertFalse(marker.exists())

    def test_disabling_then_enabling_provider_recovers_fresh_generation(self):
        from blox_widgets.model import default_widget
        command = json.dumps([sys.executable, '-m', 'blox_widgets.broker'])
        widget = json.dumps(default_widget('clock', 'clock'))
        library = json.dumps(str(self.repo / 'widgets/lib'))
        self.run_qml('''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    property int stage: 0
    property int initialGeneration: -1
    Widgets.WidgetTheme { id: theme }
    NativeProvider { id: provider; enabled: true; enableNativeMusic: false
        brokerCommand: COMMAND; brokerEnvironment: ({PYTHONPATH: LIBRARY}) }
    Widgets.WidgetHost { widget: WIDGET; theme: theme; provider: provider
        workspace: ({id:1,name:"1",special:false,empty:true})
        onPhaseChanged: {
            if (phase === "visible" && stage === 0) { initialGeneration=revealGeneration; stage=1; disable.restart() }
            else if (phase === "unavailable" && stage === 1) { stage=2; enable.restart() }
            else if (phase === "visible" && stage === 2 && revealGeneration > initialGeneration) Qt.exit(0)
        }
    }
    Timer { id: disable; interval: 20; onTriggered: provider.enabled=false }
    Timer { id: enable; interval: 20; onTriggered: provider.enabled=true }
    Timer { interval: 1500; running: true; onTriggered: Qt.exit(3) }
}'''.replace('COMMAND', command).replace('LIBRARY', library).replace('WIDGET', widget))

    def test_command_complete_output_errors_and_fresh_reveal_through_transport(self):
        from blox_widgets.model import default_widget
        marker = self.root / 'command-starts'
        source = ('import sys,time; from pathlib import Path; '
            'p=Path("command-starts"); count=int(p.read_text())+1 if p.exists() else 1; '
            'p.write_text(str(count)); print(f"Public fixture {count}",end="",flush=True); '
            'time.sleep(.15); print(" complete"); sys.exit(9 if count==3 else 0)')
        item = default_widget('command', 'public-fixture', {
            'command': [sys.executable, '-u', '-c', source], 'workingDirectory': str(self.root),
            'intervalSeconds': .25})
        self.run_qml('''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    id: root
    property int stage: 0
    property int previousGeneration: -1
    property bool freshPreparing: false
    property string acceptedFrame: ""
    NativeProvider { id: provider; enabled: true
        brokerCommand: COMMAND; brokerEnvironment: ({PYTHONPATH: LIBRARY})
        onConnectionError: Qt.exit(2)
    }
    FloatingWindow {
        visible: true; implicitWidth: 600; implicitHeight: 400
        Widgets.WidgetHost { id: host; widget: WIDGET; provider: provider
            onPhaseChanged: if (phase === "visible") Qt.callLater(check)
            onSnapshotChanged: if (phase === "visible") Qt.callLater(check)
            function check() {
                if (phase !== "visible") return
                const frame = revealGeneration + ":" + snapshot.revision
                if (root.acceptedFrame === frame) return
                root.acceptedFrame = frame
                if (root.stage === 0) {
                    if (view.outputText !== "Public fixture 1 complete" || error !== "") { Qt.exit(4); return }
                    root.previousGeneration = revealGeneration
                    root.stage = 1
                    visible = false
                    if (snapshot !== null) { Qt.exit(5); return }
                    reveal.start()
                } else if (root.stage === 1) {
                    if (!root.freshPreparing || revealGeneration <= root.previousGeneration
                        || view.outputText !== "Public fixture 2 complete" || error !== "") { Qt.exit(6); return }
                    root.previousGeneration = revealGeneration
                    root.stage = 2
                } else if (root.stage === 2) {
                    if (revealGeneration !== root.previousGeneration || view.outputText !== "Public fixture 2 complete"
                        || error !== "Command exited with code 9" || view.outputError !== error) { Qt.exit(7); return }
                    Qt.exit(0)
                }
            }
        }
    }
    Timer { id: reveal; interval: 20; onTriggered: { host.visible = true; fresh.start() } }
    Timer { id: fresh; interval: 20; onTriggered: {
        if (host.phase !== "preparing" || !host.view || host.view.outputText !== "") { Qt.exit(8); return }
        root.freshPreparing = true
    } }
    Timer { interval: 3000; running: true; onTriggered: Qt.exit(3) }
}'''.replace('COMMAND', json.dumps([sys.executable, '-m', 'blox_widgets.broker']))
            .replace('LIBRARY', json.dumps(str(self.repo / 'widgets/lib'))).replace('WIDGET', json.dumps(item)))
        self.assertEqual(marker.read_text(), '3')

    def test_terminal_first_live_frame_paints_with_configured_environment(self):
        from unittest.mock import patch
        from PySide6.QtGui import QImage
        from blox_widgets.model import default_widget
        marker = self.root / 'broker-starts.jsonl'
        helper = self.root / 'broker.py'
        helper.write_text('import json,os,pathlib,runpy,sys\n'
            'pathlib.Path(sys.argv[1]).open("a").write(json.dumps({"configured": bool(os.environ.get("PYTHONPATH"))})+"\\n")\n'
            'runpy.run_module("blox_widgets.broker",run_name="__main__")\n')
        command = json.dumps([sys.executable, str(helper), str(marker)])
        capture = self.root / 'terminal.png'
        item = default_widget('terminal', 'public-fixture', {'columns': 30, 'rows': 4,
            'command': [sys.executable, '-c',
                'import sys,time;sys.stdout.write("\\x1b[41m    \\x1b[0m PUBLIC FIXTURE\\r\\n");sys.stdout.flush();time.sleep(3)']})
        item['placement'].update(x=0, y=0, width=500, height=200)
        item['appearance']['backgroundOpacity'] = 0
        qml = ('''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    Widgets.WidgetTheme { id: theme; monospaceFamily: "MartianMono Nerd Font Mono"
        palette: ({background: "#161a20", foreground: "#ffffff"}) }
    NativeProvider { id: provider; enabled: true; enableNativeMusic: false
        brokerCommand: COMMAND; brokerEnvironment: ({PYTHONPATH: LIBRARY})
        onConnectionError: Qt.exit(2)
    }
    FloatingWindow {
        visible: true; implicitWidth: 500; implicitHeight: 200; color: "#112233"
        Widgets.WidgetHost { id: host; widget: WIDGET; theme: theme; provider: provider
            onPhaseChanged: if (phase === "visible") capture.restart()
        }
    }
    Timer { id: capture; interval: 100
        onTriggered: host.grabToImage(function(result) { result.saveToFile(OUTPUT); Qt.exit(0); })
    }
    Timer { interval: 1500; running: true; onTriggered: Qt.exit(3) }
}'''.replace('COMMAND', command).replace('LIBRARY', json.dumps(str(self.repo / 'widgets/lib')))
            .replace('WIDGET', json.dumps(item)).replace('OUTPUT', json.dumps(str(capture))))
        with patch.dict(os.environ):
            os.environ.pop('PYTHONPATH', None)
            self.run_qml(qml)
        starts = [json.loads(line) for line in marker.read_text().splitlines()]
        self.assertEqual(starts, [{'configured': True}])
        image = QImage(str(capture))
        self.assertFalse(image.isNull())
        white, red = 0, 0
        for y in range(image.height()):
            for x in range(image.width()):
                pixel = image.pixelColor(x, y)
                if pixel.alpha() < 200:
                    continue
                white += pixel.red() > 180 and pixel.green() > 180 and pixel.blue() > 180
                red += pixel.red() > 100 and pixel.red() > pixel.green() * 2 and pixel.red() > pixel.blue() * 2
        self.assertGreater(white, 100, 'The first asynchronous terminal observation must paint its glyphs')
        self.assertGreater(red, 100, 'The first asynchronous terminal observation must paint ANSI backgrounds')

    def test_transport_reconnect_retains_host_demand_and_reveals_fresh_generation(self):
        from blox_widgets.model import default_widget
        helper = self.root / 'crash_once.py'
        helper.write_text('''import json,os,pathlib,runpy,sys,time
marker=pathlib.Path(sys.argv[1])
if marker.exists():
    runpy.run_module("blox_widgets.broker",run_name="__main__")
else:
    marker.touch()
    for line in sys.stdin:
        request=json.loads(line)
        if request.get("op")=="subscribe":
            print(json.dumps({"consumerId":request["consumerId"],"snapshot":{
                "generation":request["generation"],"revision":1,"observedMonotonicMs":time.monotonic()*1000,
                "state":"ready","value":{"epochMs":time.time()*1000,"hour":1,"minute":2,"second":3},"error":""}}),flush=True)
            time.sleep(.1)
            os._exit(7)
''')
        command = json.dumps([sys.executable, str(helper), str(self.root / 'crashed')])
        widget = json.dumps(default_widget('clock', 'clock'))
        library = json.dumps(str(self.repo / 'widgets/lib'))
        self.run_qml('''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    property bool sawVisible: false
    property bool sawDisconnected: false
    property int firstGeneration: -1
    Widgets.WidgetTheme { id: theme }
    NativeProvider { id: provider; enabled: true; enableNativeMusic: false
        brokerCommand: COMMAND; brokerEnvironment: ({PYTHONPATH: LIBRARY}) }
    Widgets.WidgetHost { id: host; widget: WIDGET; theme: theme; provider: provider
        workspace: ({id:1,name:"1",special:false,empty:true})
        onPhaseChanged: {
            if (phase === "visible" && !sawVisible) { sawVisible=true; firstGeneration=revealGeneration }
            else if (phase === "unavailable" && sawVisible) sawDisconnected=true
            else if (phase === "visible" && sawDisconnected && revealGeneration > firstGeneration) Qt.exit(0)
        }
    }
    Timer { interval: 5500; running: true; onTriggered: Qt.exit(3) }
}'''.replace('COMMAND', command).replace('LIBRARY', library).replace('WIDGET', widget))


    def test_action_response_errors_and_cancelled_generations_do_not_replace_content(self):
        broker_source = json.dumps((self.repo / 'widgets/qml/Blox/Widgets/Providers/QuickshellBroker.qml').as_uri())
        self.run_qml('''import QtQuick
import Quickshell
Scope {
    property int frames: 0
    property int results: 0
    Loader { id: adapter; source: SOURCE; onLoaded: check.start() }
    Timer {
        id: check; interval: 20
        onTriggered: {
            const item = adapter.item;
            item.snapshotReady.connect(function(id, snapshot) { frames++; if(snapshot.state !== "ready") Qt.exit(4); });
            item.actionResult.connect(function(id, generation, result) { results++; if (generation !== 4 || result.code !== "invalid_request") Qt.exit(5); });
            item.subscribe("fixture", "command", {}, 4);
            item.readChunk(JSON.stringify({consumerId:"fixture", snapshot:{generation:4,revision:1,state:"ready",value:{text:"retained"}}}) + "\\n");
            item.actionRequests = {2:{consumerId:"fixture",generation:4}};
            item.readChunk(JSON.stringify({requestId:2,op:"action",consumerId:"fixture",generation:4,error:{message:"invalid button"}}) + "\\n");
            if (frames !== 1 || results !== 1 || Object.keys(item.actionRequests).length !== 0) Qt.exit(6);
            item.actionRequests = {3:{consumerId:"fixture",generation:4}};
            item.unsubscribe("fixture");
            item.subscribe("fixture", "command", {}, 5);
            item.readChunk(JSON.stringify({requestId:3,op:"action",consumerId:"fixture",generation:4,error:{message:"stale"}}) + "\\n");
            if (frames !== 1 || results !== 1 || Object.keys(item.actionRequests).length !== 0) Qt.exit(7);
            Qt.exit(0);
        }
    }
    Timer { interval: 1000; running: true; onTriggered: Qt.exit(8) }
}'''.replace('SOURCE', broker_source))

    def test_mutated_command_binding_requires_fresh_generation_through_transport(self):
        from blox_widgets.model import default_widget
        for mutation in ('callback', 'before-activation'):
            with self.subTest(mutation=mutation):
                marker = self.root / f'{mutation}-actions'

                def binding(word):
                    script = f'from pathlib import Path; p=Path({str(marker)!r}); p.open("a").write({word!r} + "\\n")'
                    return dict(kind='run', command=[sys.executable, '-c', script],
                                workingDirectory='', environment={}, timeoutSeconds=5)

                widget = default_widget('command', 'fixture', {
                    'command': [sys.executable, '-c', 'print("synthetic ready")'],
                    'actions': {'left': binding('old-binding'), 'right': None}})
                source = '''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    id: root
    property int stage: 0
    property int oldGeneration: -1
    property int accepted: 0
    property var staleContext: null
    NativeProvider {
        id: provider; enabled: true; brokerCommand: BROKER; brokerEnvironment: ({PYTHONPATH:LIBRARY})
        onActionResult: (id, generation, result) => {
            if (result.code === "accepted") {
                accepted++;
                console.log("accepted generation", generation, "old generation", root.oldGeneration);
            } else if (result.code !== "busy") Qt.exit(10);
        }
    }
    FloatingWindow {
        visible: true; implicitWidth: 400; implicitHeight: 300
        Widgets.WidgetHost {
            id: host; widget: WIDGET; provider: provider
            onPhaseChanged: if (phase === "visible") Qt.callLater(activate)
            function mutate() { widget.settings.actions.left.command = NEWCOMMAND; }
            function activate() {
                if (root.stage === 0) {
                    root.stage = 1; root.oldGeneration = revealGeneration;
                    root.staleContext = view.context;
                    if (CALLBACK) actionRequested.connect(mutate);
                    else mutate();
                    view.actionRequested("activate", {button:"left"});
                    if (CALLBACK) actionRequested.disconnect(mutate);
                    console.log("after mutation generation", revealGeneration, "old generation", root.oldGeneration);
                    // Exercise the next activation immediately, even if the old view was unloaded.
                    host._action("activate", {button:"left"});
                } else if (root.stage === 1 && revealGeneration > root.oldGeneration) {
                    root.stage = 2;
                    // Neither the old adapter generation nor the old view context may run a binding.
                    provider.dispatchAction(consumerId, "activate", {button:"left"}, root.oldGeneration);
                    root.staleContext.requestAction("activate", {button:"left"});
                    view.actionRequested("activate", {button:"left"});
                }
            }
            onSnapshotChanged: if (root.stage > 0 && snapshot && snapshot.value.action
                    && snapshot.value.action.state === "finished") {
                console.log("finished generation", revealGeneration, "old generation", root.oldGeneration,
                    "stage", root.stage, "accepted", root.accepted);
                const valid = root.stage === 2 && revealGeneration > root.oldGeneration
                    && root.accepted === 1 && snapshot.value.action.result.exitCode === 0;
                provider.unsubscribe(consumerId);
                Qt.exit(valid ? 0 : 11);
            }
        }
    }
    Timer { interval: 4000; running: true; onTriggered: Qt.exit(12) }
}'''
                self.run_qml(source.replace('BROKER', json.dumps([sys.executable, '-m', 'blox_widgets.broker']))
                    .replace('LIBRARY', json.dumps(str(self.repo / 'widgets/lib')))
                    .replace('WIDGET', json.dumps(widget))
                    .replace('NEWCOMMAND', json.dumps(binding('new-binding')['command']))
                    .replace('CALLBACK', json.dumps(mutation == 'callback')))
                self.assertEqual(marker.read_text().splitlines(), ['new-binding'])

    def test_current_command_eligibility_through_owned_transport(self):
        mutations = {
            'disabled': 'widget.enabled = false;',
            'selectors': 'widget.workspaces = {mode:"include", ids:[2], ranges:[]};',
            'visibility': 'widget.visibility = "empty-workspace";',
            'ids': 'widget.workspaces.ids[0] = 2;',
            'range': 'widget.workspaces.ranges[0][0] = 2;',
            'workspace-id': 'workspace.id = 2;',
            'workspace-empty': 'workspace.empty = false;',
        }
        self._assert_current_command_subscription(mutations)

    def test_current_subscription_identity_before_kind_routing_through_owned_transport(self):
        mutations = {f'kind-{kind}': f'widget.kind = {json.dumps(kind)};'
                     for kind in ('clock', 'music', 'system', 'network', 'calendar', 'notes', 'files',
                                  'shortcuts', 'weather', 'terminal', 'qml', 'unknown', '', None)}
        mutations.update({
            'removed': 'host.widget = null;',
            'id': 'widget.id = "replacement";',
            'settings': 'widget.settings = Object.assign({}, widget.settings, {command:["replacement"]});',
            'argv': 'widget.settings.actions.left.command[2] = "replacement";',
            'environment': 'widget.settings.actions.left.environment.CHANGED = "yes";',
            'timeout': 'widget.settings.actions.left.timeoutSeconds = 4;',
            'adapter': 'host.provider = replacementProvider;',
            'named-workspace': 'workspace.name = "other";',
            'special-workspace': 'workspace.name = "other";',
        })
        self._assert_current_command_subscription(mutations, restore_immediately=True, reenter=True)

    def _assert_current_command_subscription(self, mutations, restore_immediately=False, reenter=False):
        from blox_widgets.model import default_widget

        def run_case(case):
            state, mutation, moment = case
            case_root = self.root / f'eligibility-{state}-{moment}'
            case_root.mkdir(parents=True, exist_ok=True)
            marker = case_root / 'actions'
            count = case_root / 'content'

            def command(word):
                return [sys.executable, '-c',
                    f'from pathlib import Path; import time; Path({str(marker)!r}).open("a").write({word!r} + "\\n"); time.sleep(.05)']

            producer = (f'from pathlib import Path; p=Path({str(count)!r}); '
                        'n=int(p.read_text())+1 if p.exists() else 1; '
                        'p.write_text(str(n)); print("content-"+str(n))')
            widget = default_widget('command', 'eligibility-fixture', {
                'command': [sys.executable, '-c', producer], 'intervalSeconds': 60,
                'actions': {'left': dict(kind='run', command=command('ran-while-ineligible'),
                    workingDirectory='', environment={}, timeoutSeconds=5), 'right': None}})
            if state in ('ids', 'workspace-id'):
                widget['workspaces'] = dict(mode='include', ids=[1], ranges=[])
            if state == 'range':
                widget['workspaces'] = dict(mode='include', ids=[], ranges=[[1, 1]])
            if state == 'workspace-empty':
                widget['visibility'] = 'empty-workspace'
            if state in ('named-workspace', 'special-workspace'):
                widget['workspaces'] = dict(mode='include', ids=[
                    'named' if state == 'named-workspace' else 'special:scratch'], ranges=[])
            workspace = dict(id=1, name='1', special=False, empty=state != 'visibility')
            if state in ('named-workspace', 'special-workspace'):
                workspace.update(id=-1, name='named' if state == 'named-workspace' else 'scratch',
                                 special=state == 'special-workspace')
            source = '''import QtQuick
import Quickshell
import Blox.Widgets 1.0 as Widgets
import Blox.Widgets.Providers 1.0
Scope {
    id: root
    property int stage: 0
    property int oldGeneration: -1
    property int accepted: 0
    property var oldContext: null
    NativeProvider {
        id: replacementProvider; enabled: true; brokerCommand: BROKER; brokerEnvironment: ({PYTHONPATH:LIBRARY})
        onActionResult: Qt.exit(17)
    }
    NativeProvider {
        id: provider; enabled: true; brokerCommand: BROKER; brokerEnvironment: ({PYTHONPATH:LIBRARY})
        onActionResult: (id, generation, result) => {
            console.log("eligibility action result", generation, JSON.stringify(result));
            if (result.code === "accepted") root.accepted++;
            else if (result.code !== "busy") Qt.exit(10);
        }
    }
    FloatingWindow {
        visible: true; implicitWidth: 400; implicitHeight: 300
        Widgets.WidgetHost {
            id: host; widget: WIDGET; provider: provider
            workspace: WORKSPACE
            onPhaseChanged: if (phase === "visible") Qt.callLater(probe)
            function mutate() {
                if (CALLBACK) actionRequested.disconnect(mutate);
                MUTATION
                if (CALLBACK && REENTER) root.oldContext.requestAction("activate", {button:"left"});
            }
            function restore() {
                root.stage = 2;
                host.widget = WIDGET;
                host.widget.settings.actions.left.command = CURRENT_COMMAND;
                host.workspace = WORKSPACE;
                host.provider = provider;
                host.refresh();
            }
            function probe() {
                if (root.stage === 0) {
                    root.stage = 1; root.oldGeneration = revealGeneration;
                    root.oldContext = view.context;
                    if (CALLBACK) actionRequested.connect(mutate);
                    else mutate();
                    root.oldContext.requestAction("activate", {button:"left"});
                    root.oldContext.requestAction("activate", {button:"left"});
                    host._action("activate", {button:"left"});
                    console.log("eligibility invalidation", revealGeneration, root.oldGeneration, phase,
                        "consumer retained", !!provider.consumers[consumerId], "accepted", root.accepted);
                    // On the old host, let the real action finish so the marker proves execution.
                    if (revealGeneration === root.oldGeneration) return;
                    if (phase !== "hidden" || view || snapshot || provider.consumers[consumerId]
                            || replacementProvider.consumers[consumerId]) Qt.exit(12);
                    if (RESTORE_IMMEDIATELY) { restore(); return; }
                    Qt.callLater(function() {
                        if (host.phase !== "hidden" || provider.consumers[host.consumerId]) Qt.exit(13);
                        host.restore();
                    });
                } else if (root.stage === 2) {
                    root.stage = 3;
                    provider.dispatchAction(consumerId, "activate", {button:"left"}, root.oldGeneration);
                    root.oldContext.requestAction("activate", {button:"left"});
                    host.acceptSnapshot(consumerId, {generation:root.oldGeneration, revision:999,
                        observedMonotonicMs:0, state:"ready", value:{text:"stale"}, error:""});
                    if (!snapshot || snapshot.value.text !== "content-2") Qt.exit(14);
                    view.context.requestAction("activate", {button:"left"});
                }
            }
            onSnapshotChanged: {
                if (!snapshot || !snapshot.value.action) return;
                if (snapshot.value.action.state === "finished") {
                    console.log("eligibility finished", "stage", root.stage, "generation", revealGeneration,
                        "accepted", root.accepted, JSON.stringify(snapshot.value.action.result));
                    if (root.stage === 1) { provider.unsubscribe(consumerId); Qt.exit(11); }
                    if (root.accepted !== 1 || snapshot.value.action.result.exitCode !== 0) Qt.exit(15);
                    root.stage = 4;
                }
                if (root.stage === 4 && snapshot.value.text === "content-3") {
                    console.log("eligibility current completion and single content refresh", revealGeneration);
                    provider.unsubscribe(consumerId);
                    Qt.exit(0);
                }
            }
        }
    }
    Timer { interval: 4000; running: true; onTriggered: Qt.exit(16) }
}'''
            self.run_qml(source.replace('BROKER', json.dumps([sys.executable, '-m', 'blox_widgets.broker']))
                .replace('LIBRARY', json.dumps(str(self.repo / 'widgets/lib')))
                .replace('WIDGET', json.dumps(widget))
                .replace('WORKSPACE', json.dumps(workspace))
                .replace('MUTATION', mutation).replace('CALLBACK', json.dumps(moment == 'callback'))
                .replace('RESTORE_IMMEDIATELY', json.dumps(restore_immediately))
                .replace('REENTER', json.dumps(reenter))
                .replace('CURRENT_COMMAND', json.dumps(command('current-action'))),
                workdir=case_root)
            return state, moment, marker.read_text().splitlines(), count.read_text()

        cases = [(state, mutation, moment) for state, mutation in mutations.items() for moment in ('callback', 'before')]
        workers = min(8, os.cpu_count() or 4, len(cases))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for state, moment, actions, content_count in pool.map(run_case, cases):
                with self.subTest(state=state, moment=moment):
                    self.assertEqual(actions, ['current-action'])
                    self.assertEqual(content_count, '3')

    def test_command_run_transport_busy_failure_and_single_refresh(self):
        from blox_widgets.model import default_widget
        producer = 'from pathlib import Path; p=Path("count"); p.write_text(str(int(p.read_text())+1) if p.exists() else "1"); print("public fixture")'
        binding = dict(kind='run',command=[sys.executable,'-c','import time,sys; time.sleep(.1); print("discard"); sys.exit(7)'],
                       workingDirectory=str(self.root),environment={},timeoutSeconds=5)
        options = default_widget('command','fixture',{'command':[sys.executable,'-c',producer],
            'workingDirectory':str(self.root),'actions':{'left':binding,'right':None}})['settings']
        source = '''import QtQuick
import Quickshell
import Blox.Widgets.Providers 1.0
Scope {
    property int stage: 0
    property int accepted: 0
    property int busy: 0
    property int invalid: 0
    NativeProvider {
        id: provider; enabled: true; brokerCommand: COMMAND; brokerEnvironment: ({PYTHONPATH:LIBRARY})
        onSnapshotReady: (id, snapshot) => {
            if (snapshot.state !== "ready") return;
            if (snapshot.value.text !== "public fixture" || snapshot.error) Qt.exit(3);
            if (stage === 0) {
                stage=1;
                provider.dispatchAction("fixture","activate",{button:"missing"},7);
            } else if (stage === 2 && snapshot.value.action.state === "finished") {
                if (snapshot.value.action.result.exitCode !== 7) Qt.exit(4);
                settle.restart();
            }
        }
        onActionResult: (id, generation, result) => {
            if (generation !== 7) Qt.exit(5);
            if (result.code === "invalid_request") {
                invalid++; stage=2;
                provider.dispatchAction("fixture","activate",{button:"left"},7);
                provider.dispatchAction("fixture","activate",{button:"left"},7);
            } else if (result.code === "accepted") accepted++;
            else if (result.code === "busy") busy++;
        }
    }
    Component.onCompleted: provider.subscribe("fixture","command",OPTIONS,7)
    Timer { id: settle; interval: 250; onTriggered: { provider.unsubscribe("fixture"); Qt.exit(accepted===1 && busy===1 && invalid===1 ? 0 : 6); } }
    Timer { interval: 4000; running: true; onTriggered: Qt.exit(7) }
}'''
        self.run_qml(source.replace('COMMAND',json.dumps([sys.executable,'-m','blox_widgets.broker']))
            .replace('LIBRARY',json.dumps(str(self.repo/'widgets/lib'))).replace('OPTIONS',json.dumps(options)))
        self.assertEqual((self.root/'count').read_text(),'2')


if __name__ == '__main__':
    unittest.main()
