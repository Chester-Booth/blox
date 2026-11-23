"""One bounded JSONL process for the active widget consumers.

Run with python -m blox_widgets.broker. No desktop, input or shell APIs are used.
"""
from __future__ import annotations

import json
import ctypes
import math
import os
import selectors
import signal
import sys
import time
from collections import OrderedDict, deque
from dataclasses import dataclass, field

from .providers import create_provider
from .action_context import ContextUnavailable
from . import ownership

MAX_LINE = 65536
MAX_RESPONSE = 8 * 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024
MAX_CONSUMERS = 128
MAX_WORKERS = 4
TERMINAL_FRAME_SECONDS = .016
TERMINAL_BURST_SECONDS = .008
TERMINAL_PARSE_SECONDS = .002


@dataclass(eq=False)
class DescriptorEvent:
    kind: str
    group: object = None
    session: object = None
    generation: object = None


class OutputQueue:
    """Coalesce observations and encode one frame only when stdout can drain.

    Fanout retains shared value objects instead of N encoded payload copies. At
    most one pending observation per live consumer, 256 small control replies
    and one encoded frame are retained. A partially written JSON line completes
    before the next frame, including when its consumer hides meanwhile.
    """
    def __init__(self):
        self.snapshots = OrderedDict()
        self.wire_bases = OrderedDict()
        self.controls = deque()
        self.control_bytes = 0
        self.active, self.offset, self.active_consumer = b'', 0, None

    def emit(self, message):
        if 'snapshot' in message:
            consumer = message['consumerId']
            if consumer not in self.snapshots and len(self.snapshots) >= MAX_CONSUMERS:
                # Main removes unsubscribed entries. This also bounds standalone use.
                evicted, _ = self.snapshots.popitem(last=False)
                self.wire_bases.pop(evicted, None)
            self.snapshots[consumer] = message
        else:
            raw = (json.dumps(message, separators=(',', ':'), allow_nan=False) + '\n').encode()
            if len(raw) > MAX_LINE or len(self.controls) >= 256 or self.control_bytes + len(raw) > MAX_OUTPUT - MAX_RESPONSE:
                raise BufferError('Control response queue exceeds limit')
            self.controls.append(raw)
            self.control_bytes += len(raw)

    def cancel_consumer(self, consumer):
        self.snapshots.pop(consumer, None)
        self.wire_bases.pop(consumer, None)
        if self.active_consumer == consumer and self.offset == 0:
            self.active, self.active_consumer = b'', None

    def _encode_snapshot(self, consumer, message):
        # Only broker-tagged terminal observations use this transport. Provider
        # rows are immutable snapshots; retain references, never edit their runs.
        terminal = message.get('_terminal', False)
        if not terminal:
            self.wire_bases.pop(consumer, None)
            return message, None
        message = {key: value for key, value in message.items() if key != '_terminal'}
        envelope = dict(message['snapshot'])
        value = dict(envelope['value'])
        base = self.wire_bases.get(consumer)
        next_base = None
        if 'rows' in value:
            identity = tuple(value[key] for key in ('generation', 'attempt', 'columns', 'rowCount'))
            rows = value['rows']
            next_base = (identity, envelope['revision'], value['sequence'], rows)
            value.pop('changedRuns', None)
            if (base is not None and base[0] == identity
                    and envelope['revision'] > base[1] and value['sequence'] >= base[2]):
                value.pop('rows')
                value.update(rowFormat='patch-v1', baseRevision=base[1], baseSequence=base[2],
                    rowPatches=[[index, row] for index, row in enumerate(rows) if row != base[3][index]])
            else:
                value['rowFormat'] = 'full-v1'
        envelope['value'] = value
        message['snapshot'] = envelope
        return message, next_base

    def __bool__(self):
        return bool(self.active or self.controls or self.snapshots)

    def chunk(self, limit=65536):
        if not self.active:
            self.offset = 0
            self.active_consumer = None
            if self.controls:
                self.active = self.controls.popleft()
                self.control_bytes -= len(self.active)
            elif self.snapshots:
                consumer, message = self.snapshots.popitem(last=False)
                self.active_consumer = consumer
                wire, base = self._encode_snapshot(consumer, message)
                self.active = (json.dumps(wire, separators=(',', ':'), allow_nan=False) + '\n').encode()
                if len(self.active) > MAX_RESPONSE:
                    raise BufferError('Snapshot exceeds output limit')
                # Commit only after successful encoding. A partial line always
                # finishes before the next snapshot can be serialised.
                self.wire_bases.pop(consumer, None)
                if base is not None:
                    self.wire_bases[consumer] = base
                    if len(self.wire_bases) > MAX_CONSUMERS:
                        self.wire_bases.popitem(last=False)
            else:
                return b''
        return self.active[self.offset:self.offset + limit]

    def advance(self, count):
        self.offset += count
        if self.offset >= len(self.active):
            self.active, self.offset, self.active_consumer = b'', 0, None


def validate_json(value, depth=0):
    if depth > 12:
        raise ValueError('JSON nesting exceeds limit')
    if value is None or type(value) is bool:
        return
    if type(value) in (int, float):
        if not math.isfinite(value) or abs(value) > 1e18:
            raise ValueError('Invalid JSON number')
    elif isinstance(value, str):
        if len(value) > 16384:
            raise ValueError('JSON string exceeds limit')
    elif isinstance(value, list):
        if len(value) > 256:
            raise ValueError('JSON array exceeds limit')
        for item in value:
            validate_json(item, depth + 1)
    elif isinstance(value, dict):
        if len(value) > 128:
            raise ValueError('JSON object exceeds limit')
        for key, item in value.items():
            if not isinstance(key, str) or len(key) > 128:
                raise ValueError('Invalid JSON key')
            validate_json(item, depth + 1)
    else:
        raise ValueError('Invalid JSON value')


def identifier(value, field_name):
    if not isinstance(value, str) or not value or len(value) > 128:
        raise ValueError(f'Invalid {field_name}')
    return value


def _sample_worker(provider, now, descriptor, parent_pid):
    """Read once in an owned child, with no inherited broker protocol handles."""
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    try:
        # The broker is Linux-only. A killed broker must not leave a blocked reader.
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), 'Cannot set worker parent-death signal')
        if os.getppid() != parent_pid:
            return
        null = os.open(os.devnull, os.O_RDWR)
        for target in (0, 1, 2):
            os.dup2(null, target)
        if null > 2:
            os.close(null)
        # Children must not retain another worker's pipe or any terminal master.
        for entry in os.listdir('/proc/self/fd'):
            inherited = int(entry)
            if inherited > 2 and inherited != descriptor:
                try:
                    os.close(inherited)
                except OSError:
                    pass
        try:
            response = {'value': provider.sample(now)}
            raw = json.dumps(response, separators=(',', ':'), allow_nan=False).encode()
            if len(raw) > MAX_RESPONSE:
                raise ValueError('Provider observation exceeds result limit')
        except Exception as error:
            raw = json.dumps({'error': str(error)[:512]}, separators=(',', ':')).encode()
        raw += b'\n'
        while raw:
            count = os.write(descriptor, raw[:65536])
            raw = raw[count:]
    finally:
        os.close(descriptor)


class ReadWorker:
    """One cancellable observation. The thread-free broker owns at most four children."""
    def __init__(self, provider, now):
        self.buffer, self.response = bytearray(), None
        self.error, self.cancelled, self.exited = None, False, False
        reader, writer = os.pipe2(os.O_CLOEXEC)
        parent_pid = os.getpid()
        try:
            pid = os.fork()
        except BaseException:
            os.close(reader)
            os.close(writer)
            raise
        if pid == 0:
            os.close(reader)
            try:
                _sample_worker(provider, now, writer, parent_pid)
            finally:
                os._exit(0)
        os.close(writer)
        os.set_blocking(reader, False)
        self.descriptor, self.pid = reader, pid

    def _reap(self):
        if not self.exited:
            try:
                reaped, _ = os.waitpid(self.pid, os.WNOHANG)
                self.exited = bool(reaped)
            except ChildProcessError:
                self.exited = True
        return self.exited

    def _close_pipe(self):
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None

    def done(self):
        if self.descriptor is not None and self.response is None and self.error is None:
            try:
                chunk = os.read(self.descriptor, 65536)
                self.buffer.extend(chunk)
                if len(self.buffer) > MAX_RESPONSE + 1:
                    self.error = 'Provider observation exceeds result limit'
                    self.cancel()
                elif b'\n' in self.buffer:
                    line, _, extra = self.buffer.partition(b'\n')
                    if extra:
                        raise ValueError('Unexpected worker output')
                    self.response = json.loads(line)
                    self._close_pipe()
                elif not chunk:
                    self.error = 'Provider worker exited without an observation'
                    self._close_pipe()
            except BlockingIOError:
                pass
            except (OSError, ValueError, UnicodeError) as error:
                self.error = str(error)[:512]
                self.cancel()
        self._reap()
        return self.exited and (self.response is not None or self.error is not None or self.cancelled)

    def result(self):
        if self.error:
            raise ValueError(self.error)
        if not isinstance(self.response, dict):
            raise ValueError('Provider worker returned no observation')
        if 'error' in self.response:
            raise ValueError(str(self.response['error'])[:512])
        return self.response.get('value')

    def cancel(self):
        self.cancelled = True
        self._close_pipe()
        if not self._reap():
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            # Bound cleanup even if the kernel cannot interrupt a filesystem call.
            deadline = time.monotonic() + ownership.CLEANUP_SECONDS
            while not self._reap() and time.monotonic() < deadline:
                time.sleep(.002)
            if not self._reap():
                ownership.fail_service()


@dataclass(eq=False)
class Group:
    name: str
    provider: object
    consumers: dict = field(default_factory=dict)
    due: float = 0
    revision: int = 0
    future: object = None
    started: float = 0
    closed: bool = False
    sequence: int = 0
    timed_out: bool = False
    required_sequence: dict = field(default_factory=dict)
    frame_due: float | None = None
    frame_slot: float | None = None
    last_output: float | None = None
    read_bytes: int = 0
    read_done: bool = False
    admitted: bool = False
    terminal_failed: bool = False
    terminal_options: dict | None = None
    terminal_generation: int = 0
    attempt: int = 0
    lifetime_deadline: float = math.inf
    restart_due: float | None = None
    restart_delay: float = .5
    terminal_value: dict | None = None


class Broker:
    """Thread-free scheduler; worker completions are accepted only for live groups."""
    def __init__(self, emit, factory=create_provider, clock=time.monotonic, worker_timeout=14, cancel_output=None, selector=None):
        self.emit, self.factory, self.clock = emit, factory, clock
        self.groups, self.consumers = OrderedDict(), {}
        self.worker_timeout = worker_timeout
        self.cancel_output = cancel_output
        self.pending = set()
        self.stopped = False
        self.selector = selector if selector is not None else selectors.DefaultSelector()
        self.owns_selector = selector is None
        self.descriptors = {}
        self.runnable = deque()
        self.frames = deque()
        self.child_signal = None

    def _register(self, fd, kind, group=None):
        if fd is None:
            return
        session = group.provider if group else None
        event = DescriptorEvent(kind, group, session, session.generation if session else None)
        self.selector.register(fd, selectors.EVENT_READ, event)
        self.descriptors[fd] = event

    def _unregister(self, fd):
        if fd in self.descriptors:
            del self.descriptors[fd]
            self.selector.unregister(fd)

    def _detach_terminal(self, group):
        # Invalidate returned selector events before the owner can reuse an FD.
        for fd, event in list(self.descriptors.items()):
            if event.group is group:
                self._unregister(fd)
        group.frame_due = None
        group.admitted = False
        group.read_bytes, group.read_done = 0, False
        self.runnable = deque(item for item in self.runnable if item is not group)
        self.frames = deque(item for item in self.frames if item is not group)

    def _watch_child_signal(self):
        """One wakeup pipe only on Linux runtimes without pidfd support."""
        if self.child_signal is not None:
            return
        reader, writer = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        previous = signal.getsignal(signal.SIGCHLD)
        def wake(signum, frame):
            try:
                os.write(writer, b'x')
            except BlockingIOError:
                pass
            if callable(previous):
                previous(signum, frame)
        try:
            self._register(reader, 'childexit')
            signal.signal(signal.SIGCHLD, wake)
        except BaseException:
            self._unregister(reader)
            os.close(reader)
            os.close(writer)
            raise
        self.child_signal = reader, writer, previous

    def _attach_terminal(self, group):
        session = group.provider
        session.before_close = lambda: self._detach_terminal(group)
        try:
            self._register(session.readable_fd, 'terminal', group)
            if session.exit_fd is None:
                self._watch_child_signal()
            else:
                self._register(session.exit_fd, 'childexit', group)
            # Recheck after installing the watcher, including immediate exit.
            self._child_exited(group)
        except Exception as error:
            self._terminal_error(group, error)

    def _terminal_error(self, group, error):
        self._detach_terminal(group)
        group.terminal_failed = True
        group.restart_due = None
        group.lifetime_deadline = math.inf
        if group.provider is not None:
            group.provider.close()
        self._terminal_deliver(group, group.terminal_value or {}, 'unavailable', str(error))

    def _terminal_deliver(self, group, value, lifecycle, error=''):
        value = dict(value, restartPolicy=group.terminal_options['restartPolicy'],
                     attempt=group.attempt, lifecycle=lifecycle,
                     restartPending=group.restart_due is not None,
                     restartAtMonotonicMs=group.restart_due * 1000 if group.restart_due is not None else None)
        group.terminal_value = value
        group.sequence += 1
        self.deliver(group, 'unavailable' if lifecycle == 'unavailable' else 'ready', value, error)

    def _restart_terminal(self, group, duration):
        """Schedule once, after old descriptors and invocation cleanup are done."""
        delay = .5 if duration >= 30 else group.restart_delay
        group.restart_due = self.clock() + delay
        group.restart_delay = min(30, delay * 2)
        self._terminal_deliver(group, dict(group.terminal_value, restartDelaySeconds=delay), 'backoff')

    def _start_terminal(self, group):
        from .terminal import AnsiScreen, TerminalLaunchError
        group.restart_due = None
        group.attempt += 1
        options = group.terminal_options
        # No frame/parser/decoder state belongs to the replacement attempt.
        screen = AnsiScreen(options['rows'], options['columns'])
        group.terminal_value = dict(generation=group.terminal_generation, sequence=0,
            columns=screen.columns, rowCount=screen.rows,
            rows=[dict(runs=screen.runs(row)) for row in range(screen.rows)],
            changedRuns=[], readiness='partial', exited=False, exitCode=None,
            bytesObserved=0, stopReason=None,
            sourceCapabilities=dict(completeLiveFrames=False, unicode='combining-and-east-asian-width'))
        group.provider = None
        group.frame_slot = group.last_output = None
        try:
            group.provider = self.factory('terminal', options, generation=group.terminal_generation)
        except TerminalLaunchError as error:
            # OSError.filename can contain private configured argv or cwd.
            group.terminal_value.update(exited=True, stopReason='launch-failed',
                                        failure=dict(kind='launch-failed', errno=error.errno))
            if options['restartPolicy'] == 'always':
                self._restart_terminal(group, 0)
            else:
                group.lifetime_deadline = math.inf
                message = 'Terminal launch failed'
                if error.errno is not None:
                    message += ': ' + os.strerror(error.errno)
                self._terminal_deliver(group, group.terminal_value, 'unavailable', message)
            return
        except Exception as error:
            self._terminal_error(group, error)
            return
        # The group owns the subscription cap, including time spent in backoff.
        group.provider.deadline = math.inf
        if math.isfinite(group.lifetime_deadline) and hasattr(group.provider, 'limit_lifetime'):
            group.provider.limit_lifetime(group.lifetime_deadline)
        self._attach_terminal(group)
        if group.attempt > 1 and not group.terminal_failed:
            self._terminal_deliver(group, group.terminal_value, 'running')

    def _settle_terminal(self, group, value):
        session = group.provider
        # close() first detaches all borrowed descriptors and queued work, then
        # confirms the empty invocation cgroup and reaped direct child.
        session.close()
        group.terminal_value = value
        if group.terminal_options['restartPolicy'] == 'always':
            self._restart_terminal(group, session.exited_at - session.started)
        else:
            group.lifetime_deadline = math.inf
            self._terminal_deliver(group, value, 'retained-success' if value['exitCode'] == 0 else 'retained-failure')

    def _cap_terminal(self, group):
        group.restart_due = None
        group.lifetime_deadline = math.inf
        session = group.provider
        value = group.terminal_value
        if session is not None and not session.closed:
            session.reason = 'runtime-limit'
            session.close()
            value = session._snapshot()
        self._terminal_deliver(group, dict(value, stopReason='runtime-limit'), 'runtime-limit')

    def _admit_terminal(self, group, immediate=False):
        if group.closed or group.terminal_failed:
            return
        self._unregister(group.provider.fd)
        now = self.clock()
        if immediate:
            group.frame_due = min(group.frame_due, now) if group.frame_due is not None else now
        elif group.frame_due is None:
            slot = group.frame_slot
            group.frame_due = (now + TERMINAL_BURST_SECONDS if slot is None or group.last_output is None
                               or now - group.last_output >= 2 * TERMINAL_FRAME_SECONDS
                               else slot + TERMINAL_FRAME_SECONDS)
        if not immediate:
            group.last_output = now

    def _child_exited(self, group):
        session = group.provider
        if session.check_exit():
            self._unregister(session.exit_fd)
            session.release_exit_watch()
            if session.dirty:
                self._admit_terminal(group, immediate=True)

    def descriptor_ready(self, fd, event):
        """Ignore stale batches, including integer FD reuse after unsubscribe."""
        if self.descriptors.get(fd) is not event:
            return
        group = event.group
        if group is None:
            while True:
                try:
                    if not os.read(fd, 4096):
                        break
                except BlockingIOError:
                    break
            for group in list(self.groups.values()):
                # Snapshot polling may already have reaped the child. Let
                # check_exit finalise EOF and cancel its runtime deadline once.
                if (group.name == 'terminal' and not group.terminal_failed and group.provider is not None
                        and not group.provider.closed and group.provider.exit_fd is None):
                    self._child_exited(group)
            return
        if group.closed or event.session is not group.provider or event.generation != group.provider.generation:
            return
        try:
            if event.kind == 'terminal':
                self._admit_terminal(group)
            elif event.kind == 'childexit':
                self._child_exited(group)
        except Exception as error:
            self._terminal_error(group, error)

    def _service_terminals(self):
        for group in list(self.groups.values()):
            if group.name != 'terminal' or group.terminal_failed:
                continue
            try:
                # An earlier group's synchronous restart or cleanup can take
                # us past this group's cap. Check before admitting more work.
                now = self.clock()
                if now >= group.lifetime_deadline:
                    self._cap_terminal(group)
                    continue
                if group.restart_due is not None and now >= group.restart_due:
                    self._start_terminal(group)
            except Exception as error:
                self._terminal_error(group, error)
                continue
            if group.frame_due is not None and group.frame_due <= now and not group.admitted:
                group.admitted = True
                self.runnable.append(group)
                self.frames.append(group)
        # One aggregate slice, rotating after each parser batch. Publication is
        # separate and limited to one snapshot per turn so protocol I/O can run.
        until = self.clock() + TERMINAL_PARSE_SECONDS
        while self.runnable and self.clock() < until:
            group = self.runnable.popleft()
            try:
                count, drained = group.provider.ingest(until, min(512, 65536 - group.read_bytes))
                group.read_bytes += count
                if count:
                    group.last_output = self.clock()
                group.read_done = drained or group.read_bytes >= 65536
                if not group.read_done:
                    self.runnable.append(group)
                if group.provider.readable_fd is None:
                    self._unregister(group.provider.fd)
            except Exception as error:
                self._terminal_error(group, error)
        # A continuation may find only EAGAIN after its previous publication.
        # Remove its future slot rather than leaving an empty frame timer.
        for group in list(self.frames):
            if group.read_done and not group.provider.dirty:
                try:
                    self._finish_admission(group)
                except Exception as error:
                    self._terminal_error(group, error)
        due = [group for group in self.frames if group.frame_due <= self.clock()]
        if not due:
            return
        group = min(due, key=lambda item: item.frame_due)
        self.frames.remove(group)
        target = group.frame_due
        try:
            value = group.provider.take_snapshot()
            if value is not None:
                if group.provider._exit_reported:
                    self._settle_terminal(group, value)
                    return
                self._terminal_deliver(group, value, 'draining' if value['exited'] else 'running')
            # Skip missed slots without moving the anchor to completion time.
            now = self.clock()
            group.frame_slot = target + max(0, int((now - target) / TERMINAL_FRAME_SECONDS)) * TERMINAL_FRAME_SECONDS
            if group.read_done:
                self._finish_admission(group)
            else:
                # Parsing can continue next turn, with protocol I/O between
                # slices. Only publication waits for the next absolute slot.
                group.frame_due = group.frame_slot + TERMINAL_FRAME_SECONDS
                self.frames.append(group)
        except Exception as error:
            self._terminal_error(group, error)

    def _finish_admission(self, group):
        group.frame_due, group.admitted = None, False
        group.read_bytes, group.read_done = 0, False
        self.frames = deque(item for item in self.frames if item is not group)
        self._register(group.provider.readable_fd, 'terminal', group)

    def error(self, request_id, code, message, consumer=None, generation=None, operation=None):
        response = {'requestId': request_id, 'error': {'code': code, 'message': str(message)[:512]}}
        if operation == 'action':
            response['op'] = 'action'
        if isinstance(consumer, str) and len(consumer) <= 128:
            response['consumerId'] = consumer
        if type(generation) is int and 0 <= generation <= 2**31 - 1:
            response['generation'] = generation
        self.emit(response)

    def handle(self, request):
        request_id = request.get('requestId') if isinstance(request, dict) else None
        if self.stopped:
            self.error(request_id, 'stopped', 'Broker has shut down')
            return
        try:
            validate_json(request)
            if not isinstance(request, dict):
                raise ValueError('Request must be an object')
            if type(request_id) not in (str, int) or isinstance(request_id, str) and len(request_id) > 128:
                raise ValueError('requestId is required')
            op = request.get('op')
            if op == 'shutdown':
                if set(request) != {'requestId', 'op'}:
                    raise ValueError('Unexpected shutdown fields')
                self.stopped = True
                self.close()
                self.emit({'requestId': request_id, 'ok': True})
                return
            consumer = identifier(request.get('consumerId'), 'consumerId')
            if op == 'unsubscribe':
                if set(request) != {'requestId', 'op', 'consumerId'}:
                    raise ValueError('Unexpected unsubscribe fields')
                self.unsubscribe(consumer)
            elif op == 'subscribe':
                if set(request) != {'requestId', 'op', 'consumerId', 'provider', 'options', 'generation'}:
                    raise ValueError('Unexpected subscribe fields')
                name, options, generation = request['provider'], request['options'], request['generation']
                identifier(name, 'provider')
                if not isinstance(options, dict) or type(generation) is not int or not 0 <= generation <= 2**31 - 1:
                    raise ValueError('Invalid options or generation')
                sampling_options = dict(options)
                if name == 'command':
                    for field in ('fontFamily', 'fontSize', 'padding'):
                        sampling_options.pop(field, None)
                if name in ('clock', 'system', 'calendar'):
                    sampling_options.pop('style', None)
                key = (name, json.dumps(sampling_options, sort_keys=True, separators=(',', ':'), allow_nan=False), consumer if name in ('terminal', 'command') else '')
                if consumer not in self.consumers and len(self.consumers) >= MAX_CONSUMERS:
                    raise ValueError('Consumer limit reached')
                self.unsubscribe(consumer)
                if key not in self.groups:
                    if name == 'terminal':
                        from .model import validate_settings
                        options = validate_settings(name, options)
                        self.groups[key] = Group(name, None, terminal_options=options,
                            terminal_generation=generation, lifetime_deadline=self.clock() + options['maxRuntimeSeconds']
                            if options['maxRuntimeSeconds'] else math.inf)
                    else:
                        provider = self.factory(name, options, generation=generation)
                        self.groups[key] = Group(name, provider)
                group = self.groups[key]
                group.consumers[consumer] = generation
                group.required_sequence[consumer] = group.sequence + 1
                self.consumers[consumer] = key
                # A new visible consumer must cause a new observation, never a cache replay.
                group.due = 0
                self.deliver(group, 'preparing', {}, '', only=consumer)
                if name == 'terminal':
                    self._start_terminal(group)
            elif op == 'action':
                if set(request) - {'hostContext'} != {'requestId', 'op', 'consumerId', 'generation', 'action', 'payload'}:
                    raise ValueError('Unexpected action fields')
                key = self.consumers.get(consumer)
                if key is None:
                    raise ValueError('Unknown consumer')
                group = self.groups[key]
                generation = request['generation']
                if type(generation) is not int or generation != group.consumers[consumer]:
                    raise ValueError('Stale action generation')
                action = identifier(request['action'], 'action')
                if not isinstance(request['payload'], dict):
                    raise ValueError('Invalid action payload')
                payload = request['payload']
                if group.name == 'command':
                    if 'hostContext' in request:
                        result = group.provider.action(action, payload, trusted_context=request['hostContext'])
                    else:
                        result = group.provider.action(action, payload)
                    if result['code'] == 'accepted':
                        group.sequence += 1
                        self.deliver(group, 'ready', group.provider.observation(), group.provider.producer_result['error'])
                        group.due = 0
                elif group.name == 'terminal':
                    if 'hostContext' in request:
                        raise ValueError('Host context is only valid for command actions')
                    if action == 'resize' and set(payload) == {'columns', 'rows'}:
                        from .terminal import _dimensions
                        _dimensions(payload['columns'], payload['rows'])
                        group.terminal_options.update(payload)
                    elif action != 'input' or set(payload) != {'text'} or not isinstance(payload['text'], str) or len(payload['text'].encode()) > 4096:
                        raise ValueError('Invalid terminal action')
                    if group.provider is not None and not group.provider.closed:
                        group.provider.action(action, payload)
                    if group.provider is not None and not group.provider.closed and group.provider.dirty:
                        self._admit_terminal(group, immediate=True)
                    result = {'code': 'accepted'}
                else:
                    raise ValueError('Provider is read-only; host handles native actions')
                self.emit({'requestId': request_id, 'op': 'action', 'consumerId': consumer,
                           'generation': generation, 'ok': True, 'result': result})
                return
            else:
                raise ValueError('Unknown operation')
            self.emit({'requestId': request_id, 'ok': True})
        except ContextUnavailable as error:
            self.error(request_id, 'unavailable', error, request.get('consumerId'),
                       request.get('generation'), request.get('op'))
        except (ValueError, TypeError, KeyError, OSError) as error:
            self.error(request_id, 'invalid_request', error, request.get('consumerId') if isinstance(request, dict) else None,
                       request.get('generation') if isinstance(request, dict) else None,
                       request.get('op') if isinstance(request, dict) else None)

    def unsubscribe(self, consumer):
        if self.cancel_output:
            self.cancel_output(consumer)
        key = self.consumers.pop(consumer, None)
        if key is None:
            return
        group = self.groups[key]
        group.consumers.pop(consumer, None)
        group.required_sequence.pop(consumer, None)
        if not group.consumers:
            group.closed = True
            if group.future:
                group.future.cancel()
                if group.future.done():
                    self.pending.discard(group.future)
            group.restart_due = None
            group.lifetime_deadline = math.inf
            if group.provider is not None:
                group.provider.close()
            del self.groups[key]

    def deliver(self, group, state, value, error, only=None):
        if group.closed:
            return
        group.revision += 1
        observed = self.clock() * 1000
        for consumer, generation in list(group.consumers.items()):
            if only is not None and only != consumer:
                continue
            if state != 'preparing' and group.sequence < group.required_sequence.get(consumer, 0):
                continue
            if self.consumers.get(consumer) not in self.groups or group.closed:
                continue
            self.emit({**({'_terminal': True} if group.name == 'terminal' else {}), 'consumerId': consumer, 'snapshot': {'generation': generation,
                'revision': group.revision, 'observedMonotonicMs': observed,
                'state': state, 'value': value, 'error': str(error)[:512]}})

    def finish(self, group, future):
        self.pending.discard(future)
        if group.closed or group.future is not future:
            return
        group.future = None
        if group.timed_out:
            group.timed_out = False
            return
        try:
            value = future.result()
            if value is not None:
                self.deliver(group, 'ready', value, '')
        except Exception as error:
            self.deliver(group, 'unavailable', {}, str(error))

    def tick(self):
        ownership.maintain_owner()
        now = self.clock()
        # Reap cancelled children without accepting their results.
        for future in list(self.pending):
            if future.done():
                self.pending.discard(future)
        for key, group in list(self.groups.items()):
            if group.future and group.future.done():
                self.finish(group, group.future)
                # Existing waiters precede this group's next attempt, including
                # consumers that subscribed while its read was running.
                self.groups.move_to_end(key)
            if group.future and not group.timed_out and now - group.started > self.worker_timeout:
                group.timed_out = True
                group.future.cancel()
                self.deliver(group, 'unavailable', {}, 'Provider observation timed out')
        for group in list(self.groups.values()):
            if group.name == 'terminal' or group.closed or group.future or now < group.due:
                continue
            asynchronous = getattr(group.provider, 'asynchronous', False)
            # Waiting groups keep their deadline and place until a slot is free.
            if asynchronous and len(self.pending) >= MAX_WORKERS:
                continue
            interval = group.provider.interval
            group.due = now + (group.provider.next_delay() if hasattr(group.provider, 'next_delay') else interval)
            if asynchronous:
                group.sequence += 1
                try:
                    group.future = ReadWorker(group.provider, now)
                    group.started = now
                    self.pending.add(group.future)
                except OSError as error:
                    self.deliver(group, 'unavailable', {}, str(error))
            else:
                group.sequence += 1
                try:
                    value = group.provider.sample(now)
                    if value is not None:
                        self.deliver(group, 'ready', value, value.get('error', '') if group.name == 'command' else '')
                except Exception as error:
                    self.deliver(group, 'unavailable', {}, str(error))
                if hasattr(group.provider, 'next_delay'):
                    group.due = self.clock() + group.provider.next_delay()
        self._service_terminals()

    def wait_seconds(self):
        now = self.clock()
        delays = [max(0, group.due - now) for group in self.groups.values() if group.name != 'terminal' and not group.future
                  and not (getattr(group.provider, 'asynchronous', False) and len(self.pending) >= MAX_WORKERS)]
        for group in self.groups.values():
            if group.name != 'terminal' or group.terminal_failed:
                continue
            if group.frame_due is not None:
                delays.append(max(0, group.frame_due - now))
            if group.restart_due is not None:
                delays.append(max(0, group.restart_due - now))
            if math.isfinite(group.lifetime_deadline):
                delays.append(max(0, group.lifetime_deadline - now))
        if self.runnable:
            delays.append(0)
        # Workers need pipe draining, timeout checks and reaping until completion.
        # Idle providers can sleep to their next deadline; selector input still wakes us.
        if self.pending:
            delays.append(.05)
        lease_delay = ownership.owner_delay()
        if lease_delay is not None:
            delays.append(lease_delay)
        return min(delays) if delays else None

    def close(self):
        for consumer in list(self.consumers):
            self.unsubscribe(consumer)
        for worker in list(self.pending):
            worker.cancel()
        self.pending = {worker for worker in self.pending if not worker.done()}
        if self.child_signal is not None:
            reader, writer, previous = self.child_signal
            signal.signal(signal.SIGCHLD, previous)
            self._unregister(reader)
            os.close(reader)
            os.close(writer)
            self.child_signal = None
        if self.owns_selector:
            self.selector.close()


def decode_request(line):
    if len(line) > MAX_LINE:
        raise ValueError('Request line exceeds limit')
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    return json.loads(line, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite JSON number')))


def main():
    selector = selectors.DefaultSelector()
    incoming, outgoing = bytearray(), OutputQueue()
    input_fd, output_fd = sys.stdin.fileno(), sys.stdout.fileno()
    os.set_blocking(input_fd, False)
    os.set_blocking(output_fd, False)
    selector.register(input_fd, selectors.EVENT_READ, DescriptorEvent('stdin'))
    output_registered = False
    broker = Broker(outgoing.emit, cancel_output=outgoing.cancel_consumer, selector=selector)
    def terminate(signum, frame):
        broker.stopped = True
        broker.close()
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        while not broker.stopped or outgoing:
            if not broker.stopped:
                broker.tick()
            if bool(outgoing) != output_registered:
                if outgoing:
                    selector.register(output_fd, selectors.EVENT_WRITE, DescriptorEvent('stdout'))
                else:
                    selector.unregister(output_fd)
                output_registered = bool(outgoing)
            timeout = broker.wait_seconds() if not broker.stopped else None
            for key, _ in selector.select(timeout):
                if key.data.kind == 'stdout':
                    try:
                        count = os.write(output_fd, outgoing.chunk())
                        outgoing.advance(count)
                    except BlockingIOError:
                        pass
                elif key.data.kind == 'stdin':
                    data = os.read(input_fd, 65536)
                    if not data:
                        return 0
                    incoming.extend(data)
                    while b'\n' in incoming:
                        line, _, rest = incoming.partition(b'\n')
                        incoming[:] = rest
                        try:
                            broker.handle(decode_request(line))
                        except (ValueError, UnicodeError, RecursionError) as error:
                            broker.error(None, 'invalid_json', error)
                    if len(incoming) > MAX_LINE:
                        broker.error(None, 'line_too_large', 'Request line exceeds limit')
                        broker.stopped = True
                        broker.close()
                elif key.data.kind in ('terminal', 'childexit'):
                    broker.descriptor_ready(key.fd, key.data)
    except (BrokenPipeError, BufferError):
        return 1
    finally:
        broker.close()
        selector.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
