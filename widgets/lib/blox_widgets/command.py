"""Owned, periodic command output captured through pipes, without a terminal grid."""
from __future__ import annotations

import os
import time

from . import ownership

MAX_OUTPUT_BYTES = 1024 * 1024
MAX_READ_BYTES = 65536
MAX_POLL_SECONDS = .01


class OwnedInvocation:
    """One service-root invocation, including descendants that leave their session."""
    def __init__(self, options, *, trusted_context=None, retain_failed_output=False):
        self.options = options
        self.retain_failed_output = retain_failed_output
        from .action_context import helper_context
        self.helper_context = helper_context(trusted_context) if trusted_context is not None else None
        self.process = None
        self.exit_code = None
        self.streams = {}
        self.output = bytearray()
        self.output_bytes = 0
        self.started = 0
        self.closed = False

    def _start(self, now):
        self.started = now
        self.output = bytearray()
        self.output_bytes = 0
        self.exit_code = None
        environment = dict(os.environ)
        environment.update(self.options['environment'])
        # Only the separate application action channel may supply this reserved key.
        environment.pop('BLOX_WIDGET_ACTION_CONTEXT', None)
        if self.helper_context is not None:
            environment['BLOX_WIDGET_ACTION_CONTEXT'] = self.helper_context
        self.process = ownership.launch(self.options['command'], environment,
            self.options['workingDirectory'], now + self.options['timeoutSeconds'])
        for name, stream in (('stdout', self.process.stdout), ('stderr', self.process.stderr)):
            os.set_blocking(stream.fileno(), False)
            self.streams[name] = stream

    def _stop_process(self):
        process = self.process
        if process is not None:
            # The supervisor acknowledges only an empty cgroup and reaped leader.
            process.close()
        for stream in self.streams.values():
            stream.close()
        self.streams = {}
        self.process = None

    def _finish(self, error=''):
        exit_code = self.exit_code
        if not error and exit_code != 0:
            error = f'Command exited with code {exit_code}'
        text = self.output.decode('utf-8', errors='replace').strip() if not error or self.retain_failed_output else ''
        self._stop_process()
        self.closed = True
        self.output = bytearray()
        return {'text': text, 'error': error, 'exitCode': exit_code,
                'bytesObserved': self.output_bytes}

    def sample(self, now):
        if self.closed:
            return None
        if self.process is None:
            try:
                self._start(now)
            except ownership.CleanupFailed:
                raise
            except ownership.OwnershipUnavailable:
                return self._finish('Delegated command execution is unavailable')
            except ownership.InvocationLaunchError as error:
                if error.phase == 'exec':
                    self.exit_code = 127
                    return self._finish()
                return self._finish('Command could not be started')
            except OSError:
                return self._finish('Command could not be started')
        if now - self.started >= self.options['timeoutSeconds']:
            return self._finish(f'Command timed out after {self.options["timeoutSeconds"]:g} seconds')
        budget, until = MAX_READ_BYTES, time.monotonic() + MAX_POLL_SECONDS
        for name, stream in list(self.streams.items()):
            while budget > 0 and time.monotonic() < until:
                try:
                    data = os.read(stream.fileno(), min(4096, budget))
                except BlockingIOError:
                    break
                if not data:
                    stream.close()
                    del self.streams[name]
                    break
                budget -= len(data)
                self.output_bytes += len(data)
                if self.output_bytes > MAX_OUTPUT_BYTES:
                    return self._finish('Command output exceeds 1 MiB')
                if name == 'stdout':
                    self.output.extend(data)
        if self.exit_code is None:
            self.exit_code = self.process.poll()
        if self.exit_code is not None and not self.streams:
            return self._finish()
        return None

    def close(self):
        self._stop_process()
        self.closed = True
        self.output = bytearray()


class CommandOutput:
    """One consumer owns a producer and at most one finite action, without overlap."""
    asynchronous = False
    interval = .05

    def __init__(self, options, clock=time.monotonic, **_):
        from .model import validate_settings
        self.options = validate_settings('command', options)
        self.clock = clock
        self.invocation = None
        self.next_due = 0
        self.last_success = ''
        self.producer_result = dict(text='', error='', exitCode=None, bytesObserved=0)
        self.action_status = dict(state='idle', result=None)
        self.action_invocation = None
        self.closed = False

    # Current owned invocation diagnostics are shared by producers and actions.
    @property
    def process(self):
        return self.invocation.process if self.invocation else None

    @property
    def streams(self):
        return self.invocation.streams if self.invocation else {}

    @property
    def started(self):
        return self.invocation.started if self.invocation else 0

    @property
    def exit_code(self):
        return self.invocation.exit_code if self.invocation else None

    def next_delay(self):
        return .05 if self.invocation else max(0, self.next_due - self.clock())

    def observation(self):
        return {**self.producer_result, 'text': self.last_success, 'action': self.action_status}

    def action(self, action, payload, *, trusted_context=None):
        if self.closed:
            raise ValueError('Command consumer is closed')
        if action != 'activate' or not isinstance(payload, dict) or set(payload) != {'button'} or payload['button'] not in ('left', 'right'):
            raise ValueError('Invalid command action')
        binding = self.options['actions'][payload['button']]
        if binding is None or binding['kind'] != 'run':
            raise ValueError('Command action is not a run binding')
        from .action_context import capture_context
        context = capture_context(trusted_context) if trusted_context is not None else None
        if self.action_invocation is not None:
            return {'code': 'busy'}
        if self.invocation:
            self.invocation.close()
        self.invocation = self.action_invocation = OwnedInvocation(binding, trusted_context=context)
        self.action_status = dict(state='running', result=None)
        return {'code': 'accepted'}

    def sample(self, now):
        if self.closed:
            return None
        if self.invocation is None:
            if now < self.next_due:
                return None
            self.next_due = now + self.options['intervalSeconds']
            self.invocation = OwnedInvocation(self.options)
        result = self.invocation.sample(now)
        if result is None:
            return None
        self.invocation = None
        if self.action_invocation is not None:
            self.action_invocation = None
            code = 'success' if not result['error'] else ('timeout' if 'timed out' in result['error']
                    else 'output-limit' if 'exceeds' in result['error'] else 'failed')
            self.action_status = dict(state='finished', result=dict(code=code, exitCode=result['exitCode'],
                error=result['error'], bytesObserved=result['bytesObserved']))
            # Exactly one completion refresh. Its start resets the periodic deadline.
            self.next_due = 0
        else:
            if not result['error']:
                self.last_success = result['text']
            self.producer_result = result
        return self.observation()

    def close(self):
        self.closed = True
        if self.invocation:
            self.invocation.close()
        self.invocation = self.action_invocation = None

