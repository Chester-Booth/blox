"""Plain command output checks using only owned Python processes and public fixtures."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from blox_widgets.broker import Broker, OutputQueue
from blox_widgets.command import CommandOutput, MAX_OUTPUT_BYTES
from blox_widgets.model import default_widget, validate_profile, validate_settings, ValidationError


class CommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='blox-command-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)

    def settings(self, source='print("Public fixture")', **changes):
        return default_widget('command', 'public-fixture', {
            'command': [sys.executable, '-u', '-c', source],
            'workingDirectory': str(self.root), **changes})['settings']

    def create(self, source='print("Public fixture")', **changes):
        session = CommandOutput(self.settings(source, **changes))
        self.addCleanup(session.close)
        return session

    def until(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.003)
        self.fail('Owned command fixture did not complete')

    def result(self, session):
        return self.until(lambda: session.sample(session.clock()))

    def running_group(self, session):
        session.sample(session.clock())
        owner = session.process
        marker = self.root / 'pids'
        recorded = self.until(lambda: marker.read_text() if marker.exists() else '')
        pids = [int(pid) for pid in recorded.split()]
        self.supervision.assert_members(self, owner, pids)
        return owner, pids

    @staticmethod
    def live(pid):
        try:
            # Dead descendants can await init's reaper after owned work stops.
            return Path(f'/proc/{pid}/stat').read_text().split(') ')[1][0] != 'Z'
        except (FileNotFoundError, ProcessLookupError):
            return False

    def assert_reaped(self, owner, pids):
        self.assertIsNotNone(owner.returncode)
        self.supervision.assert_closed(self, owner)
        with self.assertRaises(ChildProcessError):
            os.waitpid(owner.pid, os.WNOHANG)
        self.until(lambda: not any(self.live(pid) for pid in pids))

    def tree_source(self, direct_exits=False):
        return ('import os,subprocess,sys,time; from pathlib import Path; '
                'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); '
                'Path("pids").write_text(f"{os.getpid()} {child.pid}"); '
                + ('' if direct_exits else 'time.sleep(60)'))

    def test_defaults_and_complete_settings_contract(self):
        item = default_widget('command', 'public-fixture', {'command': ['printf', '%s', '']})
        self.assertEqual(item['placement']['sizing'], 'content')
        self.assertEqual(item['fullscreen']['mode'], 'native')
        settings = item['settings']
        self.assertEqual((settings['intervalSeconds'], settings['timeoutSeconds']), (60, 15))
        self.assertEqual((settings['fontFamily'], settings['fontSize'], settings['padding']), ('', 15, 24))
        self.assertEqual(validate_settings('command', settings), settings)
        for missing in settings:
            incomplete = dict(settings)
            del incomplete[missing]
            with self.subTest(missing=missing), self.assertRaises(ValidationError):
                validate_settings('command', incomplete)
        with self.assertRaisesRegex(ValidationError, 'explicit configuration'):
            default_widget('command', 'public-fixture')
        for changes in ({'command': ['']}, {'command': ['printf', '\0']}, {'columns': 80},
                        {'intervalSeconds': 0}, {'timeoutSeconds': 0}, {'padding': -1},
                        {'workingDirectory': 'relative'}, {'fontSize': True}):
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                validate_settings('command', dict(settings, **changes))
        for sizing in ('fixed', 'content'):
            item['placement']['sizing'] = sizing
            self.assertEqual(validate_profile({'schemaVersion': 1, 'widgets': [item]})['widgets'][0], item)
        item['placement']['sizing'] = 'automatic'
        with self.assertRaises(ValidationError):
            validate_profile({'schemaVersion': 1, 'widgets': [item]})

    def test_command_utf8_and_wire_budgets(self):
        settings = self.settings()
        for changes in ({'command': ['printf', '\ud800']},
                        {'command': ['printf'] + ['界' * 4096] * 6},
                        {'environment': {'FIXTURE': 'a' * 4097}}):
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                validate_settings('command', dict(settings, **changes))
        settings = self.settings(command=['printf', '界' * 4096], environment={'FIXTURE': 'é' * 2048})
        self.assertEqual(validate_settings('command', settings), settings)
        request = dict(requestId=1, op='subscribe', consumerId='x' * 128,
                       provider='command', generation=2**31 - 1, options=settings)
        self.assertLess(len(json.dumps(request).encode()), 65536)

    def test_completed_stdout_is_atomic_plain_trimmed_utf8(self):
        session = self.create('import os,time; from pathlib import Path; '
            'os.write(1,b"  <b>Public</b> \\x1b[31m \\xc3"); Path("started").touch(); '
            '\nwhile not Path("release").exists(): time.sleep(.002)\n'
            'os.write(1,b"\\xa9\\n\\xff  "); os.write(2,b"ignored stderr")')
        session.sample(session.clock())
        self.until(lambda: (self.root / 'started').exists())
        self.assertIsNone(session.sample(session.clock()))
        self.assertGreater(session.invocation.output_bytes, 0)
        self.assertEqual(session.last_success, '')
        (self.root / 'release').touch()
        value = self.result(session)
        self.assertEqual(value['text'], '<b>Public</b> \x1b[31m é\n�')
        self.assertEqual((value['error'], value['exitCode']), ('', 0))
        self.assertIsNone(session.process)
        self.assertFalse(session.streams)

    def test_poll_deadline_no_idle_helper_and_no_overlap(self):
        session = self.create('import os,time; from pathlib import Path; '
            'Path("starts").open("a").write(str(os.getpid())+"\\n"); '
            '\nwhile not Path("release").exists(): time.sleep(.002)\n'
            'print("Public fixture")', intervalSeconds=.25)
        now = [100.]
        session.clock = lambda: now[0]
        self.supervision.bind_clock(session.clock)
        session.sample(now[0])
        owner = session.process
        self.until(lambda: (self.root / 'starts').exists())
        now[0] += 10
        for _ in range(10):
            self.assertIsNone(session.sample(now[0]))
            self.assertIs(session.process, owner)
        self.assertEqual(len((self.root / 'starts').read_text().splitlines()), 1)
        (self.root / 'release').touch()
        self.assertEqual(self.result(session)['text'], 'Public fixture')
        self.assert_reaped(owner, [])
        self.assertIsNone(session.process)
        # The missed deadline permits one new invocation after the previous one ends.
        self.assertEqual(self.result(session)['error'], '')
        self.assertEqual(len((self.root / 'starts').read_text().splitlines()), 2)
        now[0] += .24
        self.assertIsNone(session.sample(now[0]))
        self.assertIsNone(session.process)
        self.assertAlmostEqual(session.next_delay(), .01)

    def test_empty_success_replaces_previous_output(self):
        session = self.create('print("   ")')
        session.last_success = 'Previous fixture'
        self.assertEqual(self.result(session)['text'], '')

    def test_argv_environment_directory_and_pipes_without_a_shell(self):
        (self.root / 'owned').write_text('cwd fixture')
        source = ('import os,sys; from pathlib import Path; '
            'print(os.environ["BLOX_COMMAND_PUBLIC_FIXTURE"],Path("owned").read_text(),'
            'sys.argv[1],sys.stdin.read(),sys.stdout.isatty(),sys.stderr.isatty(),sep="|")')
        session = self.create(command=[sys.executable, '-c', source, '$FIXTURE ; literal'],
                              environment={'BLOX_COMMAND_PUBLIC_FIXTURE': 'public'})
        value = self.result(session)
        self.assertEqual(value['error'], '')
        self.assertEqual(value['text'], 'public|cwd fixture|$FIXTURE ; literal||False|False')

    def test_nonzero_exit_retains_success_and_reports_error(self):
        session = self.create('import sys; print("discard"); print("diagnostic",file=sys.stderr); sys.exit(7)')
        session.last_success = 'Previous fixture'
        value = self.result(session)
        self.assertEqual(value['text'], 'Previous fixture')
        self.assertEqual(value['exitCode'], 7)
        self.assertEqual(value['error'], 'Command exited with code 7')

    def test_start_failure_retains_success_without_exposing_paths(self):
        session = self.create(workingDirectory=str(self.root / 'absent'))
        session.last_success = 'Previous fixture'
        value = self.result(session)
        self.assertEqual(value['text'], 'Previous fixture')
        self.assertEqual(value['error'], 'Command could not be started')
        self.assertIsNone(session.process)
        session = self.create(command=[str(self.root / 'missing-executable')])
        self.assertEqual(self.result(session)['exitCode'], 127)

    def test_exact_combined_limit_succeeds(self):
        session = self.create('import os; os.write(1,b"x"*524288); os.write(2,b"e"*524288)')
        value = self.result(session)
        self.assertEqual(value['error'], '')
        self.assertEqual(value['bytesObserved'], MAX_OUTPUT_BYTES)
        self.assertEqual(len(value['text']), 524288)

    def test_overflow_is_failure_for_stdout_stderr_and_combined(self):
        for stdout, stderr in ((MAX_OUTPUT_BYTES + 1, 0), (0, MAX_OUTPUT_BYTES + 1), (524288, 524289)):
            with self.subTest(stdout=stdout, stderr=stderr):
                session = self.create(f'import os; os.write(1,b"x"*{stdout}); os.write(2,b"e"*{stderr})')
                session.last_success = 'Previous fixture'
                value = self.result(session)
                self.assertEqual(value['text'], 'Previous fixture')
                self.assertEqual(value['error'], 'Command output exceeds 1 MiB')
                self.assertGreater(value['bytesObserved'], MAX_OUTPUT_BYTES)
                self.assertIsNone(session.invocation)
                self.assertIsNone(session.process)

    def test_maximum_escaped_output_fits_broker_frame(self):
        session = self.create('import os; os.write(1,b"\\x00"*1048576)')
        value = self.result(session)
        self.assertEqual(value['error'], '')
        queue = OutputQueue()
        queue.emit({'consumerId': 'fixture', 'snapshot': {'value': value}})
        chunks = []
        while queue:
            chunk = queue.chunk()
            chunks.append(chunk)
            queue.advance(len(chunk))
        self.assertEqual(json.loads(b''.join(chunks))['snapshot']['value']['text'], value['text'])

    def test_timeout_kills_group_reaps_and_retains_success(self):
        session = self.create(self.tree_source())
        owner, pids = self.running_group(session)
        session.last_success = 'Previous fixture'
        value = session.sample(session.started + 15)
        self.assertEqual(value['text'], 'Previous fixture')
        self.assertEqual(value['error'], 'Command timed out after 15 seconds')
        self.assert_reaped(owner, pids)

    def test_close_cancels_reaps_and_is_idempotent(self):
        session = self.create(self.tree_source())
        owner, pids = self.running_group(session)
        session.close()
        session.close()
        self.assert_reaped(owner, pids)
        self.assertIsNone(session.sample(session.clock() + 100))
        self.assertFalse(session.streams)

    def test_exit_waits_for_inherited_pipe_eof(self):
        session = self.create('import os,subprocess,sys; from pathlib import Path; '
            'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); '
            'Path("pids").write_text(str(child.pid)); print("incomplete")')
        owner, pids = self.running_group(session)
        def exited():
            self.assertIsNone(session.sample(session.clock()))
            return session.exit_code == 0
        self.until(exited)
        self.assertEqual(owner.poll(), 0)
        self.assertFalse(owner.closed)
        self.assertIsNone(session.sample(session.clock()))
        value = session.sample(session.started + 15)
        self.assertIn('timed out', value['error'])
        self.assertEqual(value['text'], '')
        self.assert_reaped(owner, pids)

    def test_success_waits_for_descendant_output_after_direct_exit(self):
        session = self.create('import subprocess,sys; '
            'subprocess.Popen([sys.executable,"-c",'
            '"import time; time.sleep(.1); print(\'descendant fixture\')"]); print("direct fixture")')
        value = self.result(session)
        self.assertEqual(value['text'], 'direct fixture\ndescendant fixture')
        self.assertEqual((value['exitCode'], value['error']), (0, ''))
        self.assertIsNone(session.process)

    def test_success_cleans_descendant_that_closed_output_pipes(self):
        session = self.create('import os,subprocess,sys; from pathlib import Path; '
            'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"],'
            'stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); '
            'Path("pids").write_text(str(child.pid)); print("complete fixture")')
        owner, pids = self.running_group(session)
        self.assertEqual(self.result(session)['text'], 'complete fixture')
        self.assert_reaped(owner, pids)

    def test_broker_waits_for_poll_deadline_after_completion(self):
        broker = Broker(lambda _: None)
        self.addCleanup(broker.close)
        broker.handle(dict(requestId=1, op='subscribe', consumerId='fixture',
            provider='command', options=self.settings(), generation=1))
        broker.tick()
        group = next(iter(broker.groups.values()))
        self.assertLessEqual(broker.wait_seconds(), .05)
        def completed():
            broker.tick()
            return group.provider.process is None
        self.until(completed)
        self.assertGreater(broker.wait_seconds(), 55)
        self.assertAlmostEqual(group.due, group.provider.next_due, places=2)
        broker.unsubscribe('fixture')
        self.assertIsNone(broker.wait_seconds())

    def test_idle_broker_selector_wakes_for_unsubscribe_and_shutdown(self):
        environment = self.supervision.environment(PYTHONPATH=str(Path(__file__).resolve().parents[1] / 'lib'))
        process = subprocess.Popen([sys.executable, '-m', 'blox_widgets.broker'],
            env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        self.addCleanup(cleanup)
        incoming = bytearray()
        def receive(predicate):
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                while b'\n' in incoming:
                    line, _, rest = incoming.partition(b'\n')
                    incoming[:] = rest
                    message = json.loads(line)
                    if predicate(message):
                        return message
                if select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    incoming.extend(os.read(process.stdout.fileno(), 65536))
            self.fail('Broker did not respond while waiting for its next poll')
        def send(message):
            process.stdin.write((json.dumps(message) + '\n').encode())
        send(dict(requestId=1, op='subscribe', consumerId='fixture',
            provider='command', options=self.settings(), generation=1))
        receive(lambda message: message.get('snapshot', {}).get('state') == 'ready')
        send(dict(requestId=2, op='unsubscribe', consumerId='fixture'))
        self.assertTrue(receive(lambda message: message.get('requestId') == 2)['ok'])
        send(dict(requestId=3, op='shutdown'))
        self.assertTrue(receive(lambda message: message.get('requestId') == 3)['ok'])
        self.assertEqual(process.wait(timeout=3), 0)

    def test_broker_unsubscribe_fresh_generation_and_independent_consumers(self):
        messages = []
        broker = Broker(messages.append)
        self.addCleanup(broker.close)
        options = self.settings(self.tree_source())
        def subscribe(consumer, generation, settings):
            broker.handle(dict(requestId=generation, op='subscribe', consumerId=consumer,
                provider='command', options=settings, generation=generation))
        subscribe('fixture', 1, options)
        broker.tick()
        group = next(iter(broker.groups.values()))
        owner, pids = self.running_group(group.provider)
        broker.handle(dict(requestId=2, op='unsubscribe', consumerId='fixture'))
        self.assert_reaped(owner, pids)
        self.assertFalse(broker.groups)
        messages.clear()
        fresh = self.settings('import sys; print("discard"); sys.exit(3)')
        subscribe('fixture', 3, fresh)
        subscribe('other-fixture', 4, fresh)
        self.assertEqual(len(broker.groups), 2)
        def completed():
            broker.tick()
            ready = [m for m in messages if m.get('snapshot', {}).get('state') == 'ready']
            return ready if len(ready) == 2 else None
        ready = self.until(completed)
        self.assertEqual({m['snapshot']['generation'] for m in ready}, {3, 4})
        for message in ready:
            self.assertEqual(message['snapshot']['value']['text'], '')
            self.assertEqual(message['snapshot']['error'], 'Command exited with code 3')
        self.assertFalse(broker.pending)

    def test_broker_periodic_failure_retains_success_in_same_generation(self):
        messages = []
        broker = Broker(messages.append)
        self.addCleanup(broker.close)
        settings = self.settings('import sys; from pathlib import Path; '
            'p=Path("once"); failed=p.exists(); p.touch(); '
            'print("discard" if failed else "Public fixture"); sys.exit(8 if failed else 0)', intervalSeconds=.25)
        broker.handle(dict(requestId=1, op='subscribe', consumerId='fixture',
            provider='command', options=settings, generation=7))
        def failed():
            broker.tick()
            return next((m for m in messages if m.get('snapshot', {}).get('error')), None)
        failure = self.until(failed)['snapshot']
        ready = [m['snapshot'] for m in messages if m.get('snapshot', {}).get('state') == 'ready']
        self.assertEqual(len(ready), 2)
        self.assertEqual([frame['value']['text'] for frame in ready], ['Public fixture'] * 2)
        self.assertEqual(failure['generation'], 7)
        self.assertEqual(failure['error'], 'Command exited with code 8')

    def test_broker_shutdown_cancels_active_command_and_pending_output(self):
        queue = OutputQueue()
        broker = Broker(queue.emit, cancel_output=queue.cancel_consumer)
        self.addCleanup(broker.close)
        broker.handle(dict(requestId=1, op='subscribe', consumerId='fixture',
            provider='command', options=self.settings(self.tree_source()), generation=1))
        broker.tick()
        session = next(iter(broker.groups.values())).provider
        owner, pids = self.running_group(session)
        broker.handle(dict(requestId=2, op='shutdown'))
        self.assertTrue(broker.stopped)
        self.assertFalse(broker.groups)
        self.assertFalse(broker.consumers)
        self.assertNotIn('fixture', queue.snapshots)
        self.assert_reaped(owner, pids)

    def test_abrupt_broker_death_kills_owned_leader(self):
        driver = ('import json,sys,time; from blox_widgets.command import CommandOutput; '
                  'session=CommandOutput(json.loads(sys.argv[1])); session.sample(time.monotonic()); '
                  'print(session.process.pid,flush=True); time.sleep(60)')
        environment = self.supervision.environment(PYTHONPATH=str(Path(__file__).resolve().parents[1] / 'lib'))
        process = subprocess.Popen([sys.executable, '-c', driver, json.dumps(self.settings('import time; time.sleep(60)'))],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        self.addCleanup(cleanup)
        owner = int(process.stdout.readline().strip())
        process.kill()
        process.wait(timeout=3)
        self.until(lambda: not self.live(owner))

    def test_broker_terminate_after_direct_exit_kills_pipe_holding_descendant(self):
        driver = ('import json,signal,sys,time; from blox_widgets.command import CommandOutput; '
                  'session=CommandOutput(json.loads(sys.argv[1])); '
                  'signal.signal(signal.SIGTERM, lambda *_: (session.close(), sys.exit(0))); '
                  'session.sample(time.monotonic()); print(session.process.pid,flush=True); time.sleep(60)')
        environment = self.supervision.environment(PYTHONPATH=str(Path(__file__).resolve().parents[1] / 'lib'))
        process = subprocess.Popen([sys.executable, '-c', driver, json.dumps(self.settings(self.tree_source(True)))],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        self.addCleanup(cleanup)
        owner = int(process.stdout.readline().strip())
        marker = self.root / 'pids'
        recorded = self.until(lambda: marker.read_text() if marker.exists() else '')
        pids = [int(pid) for pid in recorded.split()]
        self.until(lambda: not self.live(pids[0]))
        self.assertFalse(self.live(owner))
        self.assertTrue(self.live(pids[1]))
        process.terminate()
        process.wait(timeout=3)
        self.until(lambda: not any(self.live(pid) for pid in [owner, *pids]))


    def binding(self, source, **changes):
        return dict(kind='run', command=[sys.executable, '-u', '-c', source],
                    workingDirectory=str(self.root), environment={}, timeoutSeconds=5, **changes)

    def test_action_schema_complete_nested_and_aggregate_budgets(self):
        import copy
        settings = self.settings(actions={'left': self.binding('pass'), 'right': {'kind': 'launch', 'command': ['app', ';literal']}})
        self.assertEqual(validate_settings('command', settings), settings)
        self.assertEqual(self.settings()['actions'], {'left': None, 'right': None})
        malformed = [None, {}, {'left': None}, {'left': None, 'right': None, 'middle': None},
            {'left': 'shell string', 'right': None}, {'left': {'kind': 'launch', 'command': ['app'], 'environment': {}}, 'right': None}]
        for key, value in [('timeoutSeconds', 121), ('timeoutSeconds', True), ('workingDirectory', 'relative'),
                           ('command', ['']), ('command', ['app', '\0']), ('environment', {'BAD-NAME': 'x'})]:
            binding = self.binding('pass'); binding[key] = value
            malformed.append({'left': binding, 'right': None})
        for actions in malformed:
            with self.subTest(actions=actions), self.assertRaises(ValidationError):
                validate_settings('command', dict(settings, actions=actions))
        for key in self.binding('pass'):
            value = copy.deepcopy(settings); del value['actions']['left'][key]
            with self.subTest(missing=key), self.assertRaises(ValidationError):
                validate_settings('command', value)
        value = copy.deepcopy(settings)
        value['command'] = ['a'] + ['界' * 4096] * 2
        for button in ('left', 'right'):
            value['actions'][button] = {'kind': 'launch', 'command': ['a'] + ['界' * 4096] * 2}
        with self.assertRaisesRegex(ValidationError, 'combined UTF-8'):
            validate_settings('command', value)
        value = copy.deepcopy(settings)
        value['actions']['right']['command'] = ['a'] + ['界' * 4096] * 2
        with self.assertRaisesRegex(ValidationError, 'encoded JSON'):
            validate_settings('command', value)

    def test_run_cancels_producer_busy_no_queue_and_refreshes_once_after_failure(self):
        source = ('import time; from pathlib import Path; p=Path("count"); '
            'n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); '
            'print("content",flush=True); time.sleep(60) if n==2 else None')
        session = self.create(source, actions={'left': self.binding('import sys; from pathlib import Path; Path("action").touch(); sys.exit(7)'), 'right': None})
        self.assertEqual(self.result(session)['text'], 'content')
        session.next_due = 0
        session.sample(session.clock())
        self.until(lambda: (self.root / 'count').read_text() == '2')
        producer = session.process
        self.assertEqual(session.action('activate', {'button': 'left'})['code'], 'accepted')
        self.assertIsNotNone(producer.returncode)
        self.assertEqual(session.last_success, 'content')
        for _ in range(100):
            self.assertEqual(session.action('activate', {'button': 'left'})['code'], 'busy')
        finished = self.result(session)
        self.assertEqual(finished['action']['result']['exitCode'], 7)
        self.assertEqual(finished['text'], 'content')
        self.assertEqual(finished['error'], '')
        refreshed = self.result(session)
        self.assertEqual((self.root / 'count').read_text(), '3')
        self.assertEqual(refreshed['action']['state'], 'finished')
        self.assertGreater(session.next_due - session.clock(), 55)
        for _ in range(5): self.assertIsNone(session.sample(session.clock()))
        self.assertEqual((self.root / 'count').read_text(), '3')

    def test_action_deadline_overflow_descendant_eof_and_close(self):
        cases = [('import time; time.sleep(60)', 'timeout'),
                 (f'import os; os.write(2,b"x"*{MAX_OUTPUT_BYTES+1})', 'output-limit'),
                 ('import subprocess,sys; subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); print("ignored")', 'timeout')]
        for source, expected in cases:
            with self.subTest(expected=expected):
                binding = self.binding(source)
                # Overflow has its own bound; a short deadline would race fixture I/O.
                binding['timeoutSeconds'] = 2 if expected == 'output-limit' else .15
                session = self.create(actions={'left': binding, 'right': None})
                self.result(session)
                session.action('activate', {'button': 'left'})
                session.sample(session.clock())
                owner = session.process
                result = self.result(session)
                self.assertEqual(result['action']['result']['code'], expected)
                self.assertEqual(result['text'], 'Public fixture')
                self.assertIsNotNone(owner.returncode)
                session.close()
                self.assertIsNone(session.sample(session.clock()+100))
        session = self.create(actions={'left': self.binding(self.tree_source()), 'right': None})
        self.result(session)
        session.action('activate', {'button': 'left'})
        owner, pids = self.running_group(session)
        session.close()
        self.assert_reaped(owner, pids)
        self.assertIsNone(session.sample(session.clock()+100))

    def test_reserved_host_context_rejects_configuration_and_strips_inheritance(self):
        from unittest.mock import patch
        reserved = 'BLOX_WIDGET_ACTION_CONTEXT'
        settings = self.settings()
        settings['environment'][reserved] = '{"workspaceId":1}'
        with self.assertRaises(ValidationError):
            validate_settings('command', settings)
        binding = self.binding('pass'); binding['environment'][reserved] = '{"workspaceId":1}'
        with self.assertRaises(ValidationError):
            self.settings(actions={'left': binding, 'right': None})
        source = 'import os; print(os.environ.get("BLOX_WIDGET_ACTION_CONTEXT", "absent"))'
        binding = self.binding('import os; from pathlib import Path; Path("context").write_text(os.environ.get("BLOX_WIDGET_ACTION_CONTEXT", "absent"))')
        with patch.dict(os.environ, {reserved: '{"workspaceId":42}'}):
            session = self.create(source, actions={'left': binding, 'right': None})
            self.assertEqual(self.result(session)['text'], 'absent')
            session.action('activate', {'button': 'left'})
            self.result(session)
            self.assertEqual((self.root / 'context').read_text(), 'absent')

    def test_action_does_not_publish_stdout_and_empty_refresh_replaces_success(self):
        source = 'from pathlib import Path; print("" if Path("changed").exists() else "old")'
        session = self.create(source, actions={'left': self.binding('from pathlib import Path; Path("changed").touch(); print("never paint")'), 'right': None})
        self.assertEqual(self.result(session)['text'], 'old')
        session.action('activate', {'button': 'left'})
        result = self.result(session)
        self.assertEqual(result['text'], 'old')
        self.assertNotIn('never paint', json.dumps(result))
        self.assertEqual(self.result(session)['text'], '')

    def test_broker_actions_resolve_only_live_generation_and_keep_invalid_content(self):
        messages = []; broker = Broker(messages.append); self.addCleanup(broker.close)
        settings = self.settings(actions={'left': self.binding('print("ignored")'), 'right': {'kind': 'launch', 'command': ['app']}})
        broker.handle(dict(requestId=1, op='subscribe', consumerId='fixture', provider='command', options=settings, generation=9))
        self.until(lambda: (broker.tick(), next((m for m in messages if m.get('snapshot',{}).get('state')=='ready'),None))[1])
        group = next(iter(broker.groups.values()))
        def action(**changes):
            broker.handle(dict(requestId=2, op='action', consumerId='fixture', generation=9, action='activate', payload={'button':'left'}, **changes))
        for payload, generation in [({'button':'left'},8), ({'button':'right'},9), ({'button':'left','command':['evil']},9), ({'button':'middle'},9)]:
            broker.handle(dict(requestId=2, op='action', consumerId='fixture', generation=generation, action='activate', payload=payload))
            self.assertEqual(messages[-1]['op'], 'action')
            self.assertIn('error',messages[-1])
            self.assertIsNone(group.provider.invocation)
            self.assertEqual(group.provider.last_success, 'Public fixture')
        action()
        self.assertEqual(messages[-1]['result']['code'], 'accepted')
        self.assertEqual(messages[-1]['generation'], 9)
        action()
        self.assertEqual(messages[-1]['result']['code'], 'busy')
        broker.unsubscribe('fixture')
        messages.clear(); broker.tick()
        self.assertFalse(messages)
        self.assertIsNone(broker.wait_seconds())

    def test_broker_terminate_during_action_kills_descendants(self):
        settings = self.settings('import time; time.sleep(60)', actions={'left': self.binding(self.tree_source(True)), 'right': None})
        driver = ('import json,signal,sys,time; from blox_widgets.command import CommandOutput; '
            's=CommandOutput(json.loads(sys.argv[1])); '
            'signal.signal(signal.SIGTERM, lambda *_: (s.close(), sys.exit(0))); '
            's.action("activate",{"button":"left"}); '
            's.sample(time.monotonic()); print(s.process.pid,flush=True); time.sleep(60)')
        environment = self.supervision.environment(PYTHONPATH=str(Path(__file__).resolve().parents[1] / 'lib'))
        process = subprocess.Popen([sys.executable,'-c',driver,json.dumps(settings)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        def cleanup():
            if process.poll() is None: process.kill()
            process.communicate(timeout=3)
        self.addCleanup(cleanup)
        owner = int(process.stdout.readline())
        marker=self.root/'pids'
        pids=[int(pid) for pid in self.until(lambda: marker.read_text() if marker.exists() else '').split()]
        self.until(lambda: not self.live(pids[0]))
        process.terminate(); process.wait(timeout=3)
        self.until(lambda: not any(self.live(pid) for pid in [owner,*pids]))


if __name__ == '__main__':
    unittest.main()
