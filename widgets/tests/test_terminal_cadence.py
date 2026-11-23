"""Deterministic admission tests with owned raw PTYs, no desktop or producer daemon."""
import errno
import json
import math
import os
import pty
import select
import signal
import sys
import time
import tty
import unittest
from unittest.mock import patch

from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture
from blox_widgets import ownership

from blox_widgets.broker import Broker, OutputQueue, ReadWorker, TERMINAL_PARSE_SECONDS
from blox_widgets.terminal import AnsiScreen, TerminalSession, TerminalLaunchError
from blox_widgets.model import default_widget


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class FakeChild:
    returncode = None

    def poll(self):
        return self.returncode


class OwnedTerminal(TerminalSession):
    """Real PTY/parser, injected child-exit pipe and clock. Never signals a PID."""
    def __init__(self, clock, generation=1):
        self.clock = clock
        self.fd, self.slave = pty.openpty()
        tty.setraw(self.slave)
        os.set_blocking(self.fd, False)
        self.exit_fd, self.exit_writer = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        self.screen = AnsiScreen(3, 40)
        self.generation, self.sequence = generation, 0
        self.started, self.deadline = clock(), math.inf
        self.exited_at = None
        self.total_bytes, self.eof, self.closed = 0, False, False
        self.reason, self._previous = None, None
        self._dirty, self._exit_reported = False, False
        self.before_close = None
        self.process = FakeChild()
        self.ingestions, self.snapshots = 0, 0
        self.batch_cost = 0

    def ingest(self, until, byte_limit=65536):
        self.ingestions += 1
        result = super().ingest(until, byte_limit)
        self.clock.now += self.batch_cost
        return result

    def take_snapshot(self):
        result = super().take_snapshot()
        if result:
            self.snapshots += 1
        return result

    def send(self, data):
        os.write(self.slave, data)
        if not select.select([self.fd], [], [], 1)[0]:
            raise AssertionError('Owned PTY write did not become readable')

    def end_output(self):
        os.close(self.slave)
        self.slave = -1

    def exit(self, code=0):
        self.process.returncode = code
        os.write(self.exit_writer, b'x')

    def limit_lifetime(self, deadline):
        # The scheduler fixture has no child PID. Record the same absolute
        # supervisor cap while exercising the production broker and parser.
        self.supervisor_deadline = deadline

    def close(self):
        if self.closed:
            return
        before_close, self.before_close = self.before_close, None
        if before_close:
            before_close()
        self.closed = True
        os.close(self.fd)
        self.fd = -1
        self.release_exit_watch()
        os.close(self.exit_writer)
        if self.slave >= 0:
            self.end_output()
        self.process.returncode = -9 if self.process.returncode is None else self.process.returncode


class CadenceTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.output = OutputQueue()
        self.sessions = []
        def factory(name, options, generation):
            session = OwnedTerminal(self.clock, generation)
            session.screen = AnsiScreen(options['rows'], options['columns'])
            self.sessions.append(session)
            return session
        self.broker = Broker(self.output.emit, factory=factory, clock=self.clock,
                             cancel_output=self.output.cancel_consumer)
        self.addCleanup(self.broker.close)

    def subscribe(self, consumer='a', generation=1, **settings):
        self.broker.handle(dict(requestId=consumer, op='subscribe', consumerId=consumer,
                                provider='terminal', options=default_widget('terminal', 'fixture',
                                    dict(command=['owned'], **settings))['settings'], generation=generation))
        group = self.broker.groups.get(self.broker.consumers.get(consumer))
        return group.provider if group else None

    def events(self):
        events = self.broker.selector.select(0)
        for key, _ in events:
            self.broker.descriptor_ready(key.fd, key.data)
        return events

    def due(self):
        delay = self.broker.wait_seconds()
        self.assertIsNotNone(delay)
        self.clock.now += delay
        self.broker.tick()

    def frame(self, consumer='a'):
        return self.output.snapshots[consumer]['snapshot']

    def settle(self, session, code=0, data=b''):
        if data:
            session.send(data)
        session.exit(code)
        session.end_output()
        self.events()
        self.due()

    def test_always_restarts_clean_and_failed_empty_results_with_fresh_attempt(self):
        for code in (0, 7):
            with self.subTest(code=code):
                first = self.subscribe(restartPolicy='always')
                self.settle(first, code, b'old')
                group = next(iter(self.broker.groups.values()))
                retained = self.frame()
                self.assertTrue(first.closed)
                self.assertEqual(self.broker.descriptors, {})
                self.assertFalse(self.broker.frames)
                self.assertFalse(self.broker.runnable)
                self.assertEqual(retained['value']['lifecycle'], 'backoff')
                self.assertEqual(retained['value']['exitCode'], code)
                self.assertEqual(retained['value']['restartDelaySeconds'], .5)
                self.assertTrue(retained['value']['rows'][0]['runs'][0]['text'].startswith('old'))
                deadline = group.restart_due
                for _ in range(20):
                    self.broker.tick()
                    self.assertEqual(group.restart_due, deadline)
                    self.assertIs(group.provider, first)
                self.due()
                second = self.sessions[-1]
                self.assertIsNot(second, first)
                self.assertFalse(second.closed)
                fresh = self.frame()
                self.assertGreater(fresh['revision'], retained['revision'])
                self.assertEqual(fresh['generation'], retained['generation'])
                self.assertEqual(fresh['value']['attempt'], 2)
                self.assertEqual(fresh['value']['bytesObserved'], 0)
                self.assertEqual(fresh['value']['readiness'], 'partial')
                self.assertFalse(fresh['value']['restartPending'])
                self.assertTrue(all(not run['text'].strip() for row in fresh['value']['rows'] for run in row['runs']))
                self.assertIsNone(self.broker.wait_seconds())
                self.settle(second)
                self.assertEqual(self.frame()['value']['readiness'], 'settled')
                self.assertEqual(self.frame()['value']['restartDelaySeconds'], 1)
                self.assertTrue(all(not run['text'].strip() for row in self.frame()['value']['rows'] for run in row['runs']))
                self.broker.unsubscribe('a')

    def test_always_waits_for_both_exit_and_eof_and_uses_exit_duration(self):
        for eof_first in (True, False):
            with self.subTest(eof_first=eof_first):
                session = self.subscribe(restartPolicy='always')
                group = next(iter(self.broker.groups.values()))
                if eof_first:
                    session.end_output()
                else:
                    session.exit(4)
                self.events()
                self.due()
                if not eof_first:
                    self.assertEqual(self.frame()['value']['lifecycle'], 'draining')
                    session.write('rejected input')
                    self.assertEqual(select.select([session.slave], [], [], 0)[0], [])
                self.assertIsNone(group.restart_due)
                self.assertIsNone(self.broker.wait_seconds())
                self.clock.now += 40
                self.broker.tick()
                self.assertIs(group.provider, session)
                self.assertFalse(session.closed)
                if eof_first:
                    session.exit()
                else:
                    session.end_output()
                self.events()
                self.due()
                self.assertEqual(self.frame()['value']['restartDelaySeconds'], .5)
                # A long drain must not count as a stable process run.
                self.assertAlmostEqual(session.exited_at - session.started, 40.008 if eof_first else 0)
                self.assertTrue(session.closed)
                self.broker.unsubscribe('a')

    def test_short_run_backoff_is_bounded_and_stable_run_resets_at_exit(self):
        session = self.subscribe(restartPolicy='always')
        for expected in (.5, 1, 2, 4, 8, 16, 30, 30):
            self.settle(session, 1)
            self.assertEqual(self.broker.wait_seconds(), expected)
            self.due()
            session = self.sessions[-1]
        self.clock.now += 30
        session.exit()
        self.events()
        self.due()
        self.assertIsNone(self.broker.wait_seconds())
        self.clock.now += 10
        session.end_output()
        self.events()
        self.due()
        self.assertEqual(self.broker.wait_seconds(), .5)

    def test_hide_cancels_backoff_and_cap_without_spawning(self):
        first = self.subscribe(restartPolicy='always', maxRuntimeSeconds=5)
        self.settle(first)
        self.broker.unsubscribe('a')
        count = len(self.sessions)
        self.clock.now += 100
        self.broker.tick()
        self.assertEqual(len(self.sessions), count)
        self.assertIsNone(self.broker.wait_seconds())
        self.assertFalse(self.broker.groups)
        self.assertFalse(self.broker.descriptors)

    def test_cap_in_backoff_and_during_later_attempt_is_one_subscription_budget(self):
        for cap in (.25, .75):
            with self.subTest(cap=cap):
                first = self.subscribe(restartPolicy='always', maxRuntimeSeconds=cap)
                group = next(iter(self.broker.groups.values()))
                deadline = group.lifetime_deadline
                self.settle(first, data=b'retain')
                self.due()
                if cap == .75:
                    self.assertIsNot(group.provider, first)
                    self.assertTrue(first.closed)
                    self.assertEqual(group.lifetime_deadline, deadline)
                    self.assertAlmostEqual(self.broker.wait_seconds(), .25)
                    self.due()
                value = self.frame()['value']
                self.assertEqual(value['stopReason'], 'runtime-limit')
                self.assertEqual(value['lifecycle'], 'runtime-limit')
                self.assertFalse(value['restartPending'])
                self.assertIsNone(group.restart_due)
                self.assertIsNone(self.broker.wait_seconds())
                self.assertFalse(self.broker.descriptors)
                if cap == .25:
                    self.assertTrue(value['rows'][0]['runs'][0]['text'].startswith('retain'))
                self.broker.unsubscribe('a')

    def test_cap_is_rechecked_after_an_earlier_groups_slow_restart(self):
        first = self.subscribe('a', generation=3, restartPolicy='always')
        capped = self.subscribe('b', generation=7, restartPolicy='always', maxRuntimeSeconds=.75)
        group = self.broker.groups[self.broker.consumers['b']]
        self.settle(first)
        self.settle(capped, 7, b'retain')
        retained = self.frame('b')
        self.assertEqual(group.restart_due, .5)
        self.assertEqual(group.lifetime_deadline, .75)
        factory, starts = self.broker.factory, []

        def delayed_restart(name, options, generation):
            starts.append((generation, self.clock()))
            if generation == 3:
                # Time spent constructing the preceding group's replacement.
                self.clock.now += 1
            return factory(name, options, generation)

        self.clock.now = .5
        with patch.object(self.broker, 'factory', side_effect=delayed_restart):
            self.broker.tick()
        self.assertEqual(self.clock(), 1.5)
        self.assertEqual(starts, [(3, .5)])
        self.assertEqual(len(self.sessions), 3)
        self.assertIs(group.provider, capped)
        self.assertTrue(capped.closed)
        frame = self.frame('b')
        value = frame['value']
        self.assertEqual(value['attempt'], 1)
        self.assertEqual(frame['generation'], retained['generation'])
        self.assertGreater(frame['revision'], retained['revision'])
        self.assertEqual(value['rows'], retained['value']['rows'])
        self.assertEqual(value['exitCode'], 7)
        self.assertEqual(value['stopReason'], 'runtime-limit')
        self.assertEqual(value['lifecycle'], 'runtime-limit')
        self.assertFalse(value['restartPending'])
        self.assertIsNone(group.restart_due)
        self.assertEqual(group.lifetime_deadline, math.inf)
        self.assertTrue(all(event.group is not group for event in self.broker.descriptors.values()))
        self.assertFalse(self.broker.runnable)
        self.assertFalse(self.broker.frames)
        self.broker.unsubscribe('a')
        self.assertFalse(self.broker.descriptors)
        self.assertIsNone(self.broker.wait_seconds())

    def test_backoff_resize_is_used_on_new_attempt_and_stale_fd_event_is_ignored(self):
        first = self.subscribe(restartPolicy='always')
        first.send(b'old')
        event = self.events()[0][0]
        fd = first.fd
        self.settle(first)
        self.broker.handle(dict(requestId='size', op='action', consumerId='a', generation=1, action='resize',
                                payload={'columns': 120, 'rows': 50}))
        self.broker.handle(dict(requestId='input', op='action', consumerId='a', generation=1, action='input', payload={'text': 'ignored'}))
        self.due()
        second = self.sessions[-1]
        self.assertEqual(second.fd, fd)
        self.broker.descriptor_ready(event.fd, event.data)
        self.assertEqual(second.ingestions, 0)
        self.assertIsNone(self.broker.wait_seconds())
        self.assertEqual((second.screen.columns, second.screen.rows), (120, 50))
        second.send(b'new')
        self.events()
        self.due()
        self.assertEqual(self.frame()['value']['attempt'], 2)
        self.assertTrue(self.frame()['value']['rows'][0]['runs'][0]['text'].startswith('new'))

    def test_launch_failure_retries_only_for_always_and_never_fills_missing_policy(self):
        factory = self.broker.factory
        for policy in ('never', 'always'):
            with self.subTest(policy=policy):
                with patch.object(self.broker, 'factory', side_effect=TerminalLaunchError(errno.ENOENT, 'owned failure', '/private/argv-head')):
                    self.subscribe(restartPolicy=policy, maxRuntimeSeconds=5)
                    value = self.frame()['value']
                    self.assertEqual(value['stopReason'], 'launch-failed')
                    self.assertEqual(value['attempt'], 1)
                    self.assertEqual(value['failure'], {'kind': 'launch-failed', 'errno': errno.ENOENT})
                    self.assertNotIn('/private/argv-head', json.dumps(self.frame()))
                    self.assertEqual(value['restartPending'], policy == 'always')
                    if policy == 'always':
                        self.due()
                        self.assertEqual(self.frame()['value']['restartDelaySeconds'], 1)
                        self.assertEqual(self.frame()['value']['attempt'], 2)
                    else:
                        self.assertEqual(self.frame()['state'], 'unavailable')
                        self.assertIsNone(self.broker.wait_seconds())
                if policy == 'always':
                    self.assertIs(self.broker.factory, factory)
                    self.due()
                    self.assertFalse(self.sessions[-1].closed)
                    self.assertEqual(self.frame()['value']['attempt'], 3)
                self.broker.unsubscribe('a')
        self.broker.handle(dict(requestId='invalid', op='subscribe', consumerId='a', provider='terminal',
                                options={'command': ['owned']}, generation=1))
        self.assertFalse(self.broker.groups)

    def test_start_infrastructure_failure_is_not_a_launch_retry(self):
        with patch.object(self.broker, 'factory', side_effect=OSError('owned exit-watch failure')):
            self.subscribe(restartPolicy='always', maxRuntimeSeconds=5)
        self.assertEqual(self.frame()['state'], 'unavailable')
        self.assertEqual(self.frame()['value']['lifecycle'], 'unavailable')
        self.assertFalse(self.frame()['value']['restartPending'])
        self.assertIn('owned exit-watch failure', self.frame()['error'])
        self.assertIsNone(self.broker.wait_seconds())

    def test_always_infrastructure_error_needs_manual_recovery(self):
        for failure in ('selector', 'parser'):
            with self.subTest(failure=failure):
                if failure == 'selector':
                    with patch.object(self.broker.selector, 'register', side_effect=OSError('owned selector failure')):
                        session = self.subscribe(restartPolicy='always', maxRuntimeSeconds=5)
                else:
                    session = self.subscribe(restartPolicy='always', maxRuntimeSeconds=5)
                    session.send(b'x')
                    with patch('blox_widgets.terminal.os.read', side_effect=OSError(errno.EBADF, 'owned parser failure')):
                        self.events()
                        self.due()
                self.assertTrue(session.closed)
                self.assertEqual(self.frame()['state'], 'unavailable')
                self.assertEqual(self.frame()['value']['lifecycle'], 'unavailable')
                self.assertFalse(self.frame()['value']['restartPending'])
                self.assertIsNone(self.broker.wait_seconds())
                self.broker.unsubscribe('a')

    def test_idle_hidden_and_settled_have_no_pty_polls_or_frame_timer(self):
        session = self.subscribe()
        for _ in range(100):
            self.events()
            self.broker.tick()
        self.assertEqual(session.ingestions, 0)
        self.assertIsNone(self.broker.wait_seconds())
        session.end_output()
        session.exit()
        self.events()
        self.due()
        self.assertEqual(self.frame()['value']['readiness'], 'settled')
        count = session.ingestions
        self.assertEqual(self.events(), [])
        for _ in range(100):
            self.broker.tick()
        self.assertEqual(session.ingestions, count)
        self.assertIsNone(self.broker.wait_seconds())
        self.broker.unsubscribe('a')
        self.assertEqual(self.broker.descriptors, {})
        self.assertEqual(list(self.broker.runnable), [])
        self.assertNotIn('a', self.output.snapshots)

    def test_sixty_hz_changing_stream_uses_anchored_slots(self):
        session = self.subscribe()
        targets = []
        for index in range(120):
            self.clock.now = index / 60
            session.send(f'\r{index:04d}'.encode())
            self.events()
            target = self.clock() + self.broker.wait_seconds()
            targets.append(target)
            self.due()
            self.assertTrue(self.frame()['value']['rows'][0]['runs'][0]['text'].startswith(f'{index:04d}'))
            self.assertFalse(self.frame()['value']['sourceCapabilities']['completeLiveFrames'])
            self.assertIsNone(self.broker.wait_seconds())
        self.assertEqual(session.snapshots, 120)
        self.assertLessEqual(max(b - a for a, b in zip(targets, targets[1:])), 1/60 + .000001)
        # Before the first missed slot, each target stays on the original grid.
        self.assertAlmostEqual(targets[1] - targets[0], .016)
        self.assertAlmostEqual(targets[2] - targets[1], .016)

    def test_fragment_coalescing_deadline_never_slides_and_holdoff_unregisters(self):
        session = self.subscribe()
        session.send(b'\x1b[Hfirst')
        event = self.events()[0][0]
        group = next(iter(self.broker.groups.values()))
        self.assertEqual(group.frame_due, .008)
        self.assertNotIn(session.fd, self.broker.descriptors)
        for tick in (.003, .006, .0079):
            self.clock.now = tick
            session.send(b'X')
            self.broker.descriptor_ready(event.fd, event.data)
            self.assertEqual(group.frame_due, .008)
            self.assertEqual(self.events(), [])
            self.broker.tick()
            self.assertEqual(session.ingestions, 0)
        self.due()
        self.assertTrue(self.frame()['value']['rows'][0]['runs'][0]['text'].startswith('firstXXX'))
        self.assertIn(session.fd, self.broker.descriptors)

    def test_completion_cost_does_not_shift_anchor_and_idle_does_not_replay_slots(self):
        session = self.subscribe()
        session.batch_cost = .001
        session.send(b'first')
        self.events()
        self.due()
        self.clock.now = .017
        session.send(b'next')
        self.events()
        self.assertAlmostEqual(self.clock() + self.broker.wait_seconds(), .024)
        self.due()
        # Late readiness still belongs to the previous absolute slot.
        self.clock.now = .041
        session.send(b'late')
        self.events()
        group = next(iter(self.broker.groups.values()))
        self.assertAlmostEqual(group.frame_due, .040)
        self.due()
        self.assertAlmostEqual(group.frame_slot, .040)
        self.assertIsNone(self.broker.wait_seconds())
        self.clock.now = 1
        session.send(b'after idle')
        self.events()
        self.assertAlmostEqual(self.broker.wait_seconds(), .008)
        self.due()
        self.assertEqual(session.snapshots, 4)

    def test_unsubscribe_removes_already_runnable_session_and_owner_close_detaches(self):
        first, second = self.subscribe('first'), self.subscribe('second')
        first.send(b'first')
        second.send(b'second')
        self.events()
        self.due()
        queued = self.broker.frames[0]
        consumer = next(iter(queued.consumers))
        self.broker.unsubscribe(consumer)
        self.assertEqual(list(self.broker.runnable), [])
        self.assertEqual(list(self.broker.frames), [])
        self.assertNotIn(consumer, self.output.snapshots)
        remaining = second if queued.provider is first else first
        remaining.close()
        self.assertEqual(self.broker.descriptors, {})
        self.assertIsNone(self.broker.wait_seconds())

    def test_hot_terminal_shares_one_budget_and_does_not_starve_request_or_quiet_terminal(self):
        hot, quiet = self.subscribe('hot'), self.subscribe('quiet')
        hot.batch_cost = .0006
        quiet.batch_cost = .0006
        hot.send(b'H' * 4096)
        quiet.send(b'quiet')
        self.events()
        self.clock.now = .008
        started = self.clock()
        self.broker.tick()
        self.assertLessEqual(self.clock() - started, TERMINAL_PARSE_SECONDS + .0006)
        self.assertGreater(quiet.ingestions, 0)
        self.broker.handle(dict(requestId='request', op='action', consumerId='quiet', generation=1, action='input', payload={'text': 'ok'}))
        self.assertEqual(os.read(quiet.slave, 2), b'ok')
        self.broker.tick()
        self.assertEqual(self.frame('quiet')['state'], 'ready')
        self.assertLessEqual(hot.ingestions + quiet.ingestions, 8)

    def test_parser_continues_between_slots_without_constructing_extra_snapshots(self):
        session = self.subscribe()
        session.batch_cost = .00075
        session.send(b'H' * 4096)
        self.events()
        self.due()
        self.assertGreater(session.total_bytes, 0)
        self.assertLess(session.total_bytes, 4096)
        self.assertEqual(session.snapshots, 1)
        self.assertEqual(self.broker.wait_seconds(), 0)
        for _ in range(4):
            if not self.broker.runnable:
                break
            self.broker.tick()
        self.assertEqual(session.total_bytes, 4096)
        self.assertEqual(session.snapshots, 1)
        self.assertGreater(self.broker.wait_seconds(), 0)
        self.due()
        self.assertEqual(session.snapshots, 2)
        self.assertIsNone(self.broker.wait_seconds())

    def test_eof_then_exit_and_exit_then_eof_keep_independent_watchers(self):
        for eof_first in (True, False):
            with self.subTest(eof_first=eof_first):
                session = self.subscribe()
                master, child = session.fd, session.exit_fd
                session.send(b'final\xe2')
                if eof_first:
                    session.end_output()
                else:
                    session.exit(7)
                self.events()
                self.due()
                if eof_first:
                    self.assertTrue(session.eof)
                    self.assertNotIn(master, self.broker.descriptors)
                    self.assertIn(child, self.broker.descriptors)
                    self.assertEqual(self.events(), [])
                    session.exit(7)
                else:
                    self.assertNotIn(child, self.broker.descriptors)
                    self.assertIn(master, self.broker.descriptors)
                    self.assertFalse(session.eof)
                    session.end_output()
                self.events()
                self.due()
                frame = self.frame()['value']
                self.assertEqual(frame['readiness'], 'settled')
                self.assertEqual(frame['exitCode'], 7)
                self.assertIn('\ufffd', frame['rows'][0]['runs'][0]['text'])
                self.assertEqual(self.events(), [])
                self.assertIsNone(self.broker.wait_seconds())
                self.broker.unsubscribe('a')

    def test_exit_after_eof_finalises_on_child_notification(self):
        factory = self.broker.factory
        for fallback in (True, False):
            for runtime in (math.inf, 1.0):
                with self.subTest(fallback=fallback, runtime=runtime):
                    self.clock.now = 0
                    def create(name, options, generation):
                        session = factory(name, options, generation)
                        if fallback:
                            session.release_exit_watch()
                        session.deadline = runtime
                        return session
                    self.broker.factory = create
                    session = self.subscribe(maxRuntimeSeconds=0 if runtime == math.inf else runtime)

                    class ExitDuringSnapshot(FakeChild):
                        calls = 0

                        def poll(self):
                            self.calls += 1
                            # EOF and the snapshot see a running child.
                            # The later child notification observes its exit.
                            if self.calls >= 3:
                                self.returncode = 0
                            return self.returncode

                    session.process = ExitDuringSnapshot()
                    session.send(b'final')
                    session.end_output()
                    self.events()
                    self.due()
                    partial = self.frame()
                    self.assertEqual(partial['value']['readiness'], 'partial')
                    self.assertFalse(partial['value']['exited'])
                    self.assertFalse(session._exit_reported)
                    self.assertTrue(session.eof)
                    self.assertNotIn(session.fd, self.broker.descriptors)
                    self.assertEqual(self.events(), [])

                    notification = self.broker.child_signal[1] if fallback else session.exit_writer
                    os.write(notification, b'x')
                    self.events()
                    self.broker.tick()
                    final = self.frame()
                    # Cross the old cap as well, exposing false runtime expiry.
                    self.clock.now = 1.0
                    self.broker.tick()
                    self.assertIsNone(self.frame()['value']['stopReason'])
                    self.assertEqual(final['value']['readiness'], 'settled')
                    self.assertEqual(final['value']['exitCode'], 0)
                    self.assertEqual(final['value']['rows'], partial['value']['rows'])
                    self.assertEqual(final['revision'], partial['revision'] + 1)
                    self.assertEqual(final['value']['sequence'], partial['value']['sequence'] + 1)
                    self.assertTrue(session._exit_reported)
                    self.assertEqual(session.deadline, math.inf)
                    self.assertTrue(session.closed)
                    self.assertIsNone(self.broker.wait_seconds())

                    counts = session.ingestions, session.snapshots
                    for _ in range(3):
                        self.assertEqual(self.events(), [])
                        if fallback:
                            os.write(notification, b'x')
                            self.events()
                        self.broker.tick()
                        self.assertEqual(self.frame(), final)
                        self.assertEqual((session.ingestions, session.snapshots), counts)
                        self.assertIsNone(self.broker.wait_seconds())
                    self.assertEqual(session.snapshots, 2)
                    self.assertFalse(self.broker.runnable)
                    self.assertFalse(self.broker.frames)
                    self.broker.unsubscribe('a')

    def test_snapshot_exit_observation_settles_and_records_short_duration_once(self):
        session = self.subscribe(restartPolicy='always')
        group = next(iter(self.broker.groups.values()))
        group.restart_delay = 4

        class ExitDuringSnapshot(FakeChild):
            calls = 0

            def poll(self):
                self.calls += 1
                if self.calls >= 2:
                    self.returncode = 0
                return self.returncode

        session.process = ExitDuringSnapshot()
        self.clock.now = 29.9
        session.send(b'final')
        session.end_output()
        self.events()
        self.due()
        self.assertEqual(self.frame()['value']['readiness'], 'settled')
        self.assertTrue(self.frame()['value']['exited'])
        self.assertEqual(self.frame()['value']['restartDelaySeconds'], 4)
        self.assertAlmostEqual(session.exited_at, 29.908)
        self.assertTrue(session._exit_reported)
        self.assertFalse(session.dirty)
        self.assertTrue(session.closed)
        self.assertEqual(session.snapshots, 1)

    def test_silent_runtime_expiry_and_resize_need_no_output(self):
        session = self.subscribe()
        next(iter(self.broker.groups.values())).lifetime_deadline = .1
        self.assertEqual(self.broker.wait_seconds(), .1)
        self.broker.handle(dict(requestId='size', op='action', consumerId='a', generation=1, action='resize', payload={'columns': 35, 'rows': 2}))
        self.broker.tick()
        self.assertEqual(self.frame()['value']['columns'], 35)
        self.assertEqual(self.broker.wait_seconds(), .1)
        self.due()
        self.assertEqual(self.frame()['value']['stopReason'], 'runtime-limit')
        self.assertTrue(self.frame()['value']['exited'])
        self.assertEqual(self.broker.descriptors, {})
        self.assertIsNone(self.broker.wait_seconds())

    def test_stale_fd_reuse_and_unsubscribe_while_queued(self):
        old = self.subscribe()
        fd = old.fd
        old.send(b'old')
        event = self.events()[0][0]
        self.broker.unsubscribe('a')
        self.clock.now = .008
        self.broker.tick()
        new = self.subscribe(generation=2)
        self.assertEqual(new.fd, fd, 'Owned fixture must exercise actual integer FD reuse')
        self.broker.descriptor_ready(event.fd, event.data)
        self.assertIsNone(self.broker.wait_seconds())
        self.assertEqual(new.ingestions, 0)
        new.send(b'new')
        self.events()
        self.due()
        self.assertEqual(self.frame()['value']['generation'], 2)
        self.assertTrue(self.frame()['value']['rows'][0]['runs'][0]['text'].startswith('new'))

    def test_slow_stdout_retains_partial_line_latest_frame_and_final_error(self):
        session = self.subscribe()
        self.output.controls.clear()
        self.output.control_bytes = 0
        session.send(b'first')
        self.events()
        self.due()
        first = self.output.chunk()
        self.output.advance(11)
        for index in range(10):
            self.clock.now += .016
            session.send(f'\r{index}'.encode())
            self.events()
            self.due()
            self.assertEqual(len(self.output.snapshots), 1)
        self.assertEqual(self.output.chunk(), first[11:])
        with patch('blox_widgets.terminal.os.read', side_effect=OSError(errno.EBADF, 'owned read failure')):
            self.clock.now += .016
            session.send(b'failure')
            self.events()
            self.due()
        self.assertEqual(self.frame()['state'], 'unavailable')
        self.assertIn('owned read failure', self.frame()['error'])
        self.assertEqual(self.broker.descriptors, {})
        self.output.advance(len(first) - 11)
        final = json.loads(self.output.chunk())['snapshot']
        self.assertEqual(final['state'], 'unavailable')
        self.assertIsNone(self.broker.wait_seconds())

    def test_selector_registration_failure_is_visible_and_closes_owner(self):
        with patch.object(self.broker.selector, 'register', side_effect=OSError('owned registration failure')):
            session = self.subscribe()
        self.assertTrue(session.closed)
        self.assertEqual(self.frame()['state'], 'unavailable')
        self.assertEqual(self.broker.descriptors, {})
        self.assertIsNone(self.broker.wait_seconds())
        recovered = self.subscribe(generation=2)
        recovered.send(b'recovered')
        self.events()
        self.due()
        self.assertEqual(self.frame()['state'], 'ready')
        self.assertEqual(self.frame()['value']['generation'], 2)

    def test_final_settled_frame_survives_stdout_backpressure(self):
        session = self.subscribe()
        self.output.controls.clear()
        self.output.control_bytes = 0
        session.send(b'first')
        self.events()
        self.due()
        active = self.output.chunk()
        self.output.advance(7)
        session.send(b'\rfinal')
        session.end_output()
        session.exit(3)
        self.events()
        self.due()
        self.assertEqual(self.frame()['value']['readiness'], 'settled')
        self.assertEqual(self.output.chunk(), active[7:])
        self.output.advance(len(active) - 7)
        final = json.loads(self.output.chunk())['snapshot']['value']
        self.assertEqual(final['exitCode'], 3)
        self.assertEqual(final['rowFormat'], 'patch-v1')
        self.assertTrue(final['rowPatches'][0][1]['runs'][0]['text'].startswith('final'))
        self.assertIsNone(self.broker.wait_seconds())


class RealExitTests(unittest.TestCase):
    def setUp(self):
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)

    def test_pidfd_wakes_silent_child_and_missing_watch_fails_closed(self):
        for fallback in (False, True):
            with self.subTest(fallback=fallback):
                sessions, output = [], []
                def factory(name, options, generation):
                    session = TerminalSession(options, generation)
                    sessions.append(session)
                    return session
                broker = Broker(output.append, factory=factory)
                worker = None
                try:
                    def subscribe():
                        broker.handle(dict(requestId=1, op='subscribe', consumerId='a', provider='terminal',
                            generation=1, options=dict(command=[sys.executable, '-c', 'pass'], workingDirectory='',
                                                      environment={}, columns=10, rows=2, maxRuntimeSeconds=0, restartPolicy="never")))
                    if fallback:
                        with patch.object(ownership, 'launch', side_effect=ownership.OwnershipUnavailable('owned pidfd unavailable')):
                            subscribe()
                        self.assertFalse(sessions)
                        self.assertTrue(any(item.get('snapshot', {}).get('state') == 'unavailable' for item in output))
                        continue
                    else:
                        subscribe()
                    class Sample:
                        def sample(self, now):
                            return {'defaultChildHandler': signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL}
                    worker = ReadWorker(Sample(), time.monotonic())
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        for key, _ in broker.selector.select(.02):
                            broker.descriptor_ready(key.fd, key.data)
                        broker.tick()
                        if (worker.done() and any(item.get('snapshot', {}).get('value', {}).get('readiness') == 'settled'
                                                  for item in output)):
                            break
                    else:
                        self.fail('Direct child never settled')
                    self.assertIsNone(broker.wait_seconds())
                    self.assertEqual(sessions[0].process.returncode, 0)
                    self.assertEqual(worker.result(), {'defaultChildHandler': True})
                finally:
                    if worker is not None:
                        worker.cancel()
                    broker.close()


if __name__ == '__main__':
    unittest.main()
