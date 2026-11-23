"""Offline GUI handoff repro. All user data, compositor effects and children are synthetic."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'widgets/lib'))
from blox_widgets.broker import Broker
from blox_widgets.model import default_widget

CONTEXT = {'outputName': 'SYNTHETIC', 'workspace': {'id': 99, 'name': '99', 'special': False}}

# Exercise the real edit/open implementation with a file-backed fake compositor.
# The test process owns the synthetic lasting GUI; helper descendants stay in the
# invocation group. No desktop, network, calendar or installed helper is called.
FAKE_HELPER = r'''
import importlib.util, json, os, subprocess, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('actual', os.environ['SYNTHETIC_REAL_HELPER'])
actions = importlib.util.module_from_spec(spec); spec.loader.exec_module(actions)
root = Path(os.environ['SYNTHETIC_ROOT'])
def wait(name):
    deadline = time.monotonic() + 8
    while not (root/name).exists():
        if time.monotonic() > deadline: raise RuntimeError('synthetic barrier timed out')
        time.sleep(.002)
class Runtime:
    clock = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)
    launch_id = None
    window = None
    def launch(self, argv, workspace, launch_id):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        (root/'finite.pids').write_text(f'{os.getpid()} {child.pid}')
        (root/'launch.request').write_text(json.dumps({'workspace': workspace, 'count': 1}))
        wait('launch.accepted')
        self.launch_id = launch_id
        self.window = {'address':'0xabc','class':'quickshell_todo','workspace':{'id':workspace},
            'pid':1234,'floating':False,'size':[564,538],'at':[695,271]}
        wait('postlaunch.release')
        child.terminate(); child.wait()
        return 0
    def clients(self): return [dict(self.window)] if self.window else []
    def process_launch_id(self, pid): return self.launch_id if pid == 1234 else None
    def dispatch(self, value):
        if 'window.float' in value: self.window['floating'] = True
        if 'window.resize' in value:
            import re
            self.window['size'] = list(map(int, re.search(r'x = (\d+), y = (\d+)',value).groups()))
        if 'window.move' in value: self.window['at'] = [60,20]
        if 'window.move' in value or 'workspace = 1' in value:
            with (root/'effects').open('a') as stream: stream.write(value+'\n')
        if 'workspace = 1' in value: (root/'focused.one').touch()
def refresh(self, generated):
    assert not generated
    assert (root/'focused.one').exists()
    (root/'calendar.refresh').touch()
    if os.environ.get('SYNTHETIC_FAIL_REFRESH'):
        raise actions.ActionError('Synthetic refresh failure')
actions.UserActions.refresh = refresh
code = actions.main(runtime=Runtime())
if code == 0: (root/'postlaunch.done').write_text('once')
raise SystemExit(code)
'''


class ActionLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='blox-action-lifetime-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)
        self.tree = self.root / 'tree'
        for name in ['shell/scripts/widgets/action.py', 'widgets/lib/blox_widgets', 'widgets/schema', 'widgets/catalogue.json']:
            source, target = ROOT / name, self.tree / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target, ignore=shutil.ignore_patterns('__pycache__'))
            else:
                shutil.copy2(source, target)
        helper = self.tree / 'shell/scripts/widgets/user_actions.py'
        helper.write_text(FAKE_HELPER)
        home = self.root / 'home'
        todo = home / 'Documents/todo'
        todo.mkdir(parents=True)
        (todo/'1-todo.md').write_text('Synthetic todo\n')
        micro = home / '.local/bin/micro'
        micro.parent.mkdir(parents=True)
        micro.write_text('synthetic executable placeholder\n'); micro.chmod(0o700)
        self.environment = dict(os.environ, HOME=str(home), XDG_STATE_HOME=str(self.root/'state'),
            XDG_CACHE_HOME=str(self.root/'cache'), XDG_RUNTIME_DIR=str(self.root/'runtime'),
            SYNTHETIC_ROOT=str(self.root), SYNTHETIC_REAL_HELPER=str(ROOT/'shell/scripts/widgets/user_actions.py'),
            PYTHONDONTWRITEBYTECODE='1', PATH='/usr/bin:/bin')
        self.events = []
        self.broker = Broker(self.events.append)
        self.addCleanup(self.broker.close)
        self.gui = None

    def until(self, check, timeout=5):
        deadline = time.monotonic()+timeout
        while time.monotonic()<deadline:
            value = check()
            if value: return value
            time.sleep(.003)
        self.fail('Synthetic action barrier did not complete')

    @staticmethod
    def live(pid):
        try: return Path(f'/proc/{pid}/stat').read_text().split(') ')[1][0] != 'Z'
        except (FileNotFoundError, ProcessLookupError): return False

    def subscribe(self, topic='todo', timeout=None, old_route=False):
        operation = 'edit' if topic == 'todo' else 'open'
        binding = {'kind':'run', 'command':['blox-widget-action',topic,operation],
            'workingDirectory':'', 'environment':{}, 'timeoutSeconds':timeout or (10 if topic == 'todo' else 120)}
        settings = default_widget('command','fixture',{'command':[sys.executable,'-c','print("Synthetic content")'],
            'actions':{'left':None,'right':binding}})['settings']
        if old_route:
            settings['actions']['right'] = dict(binding, command=[sys.executable,
                str(self.tree/'shell/scripts/widgets/user_actions.py'),topic,operation], environment=self.environment)
        self.broker.handle(dict(requestId=1,op='subscribe',consumerId='source',generation=1,
            provider='command',options=settings))
        return {'widget':default_widget('command','fixture',settings),'action':'activate','payload':{'button':'right'},
            'identity':{'widgetId':'fixture','consumerId':'source','generation':1,'button':'right'},'hostContext':CONTEXT}

    def handoff(self, tick=False):
        def ready():
            if tick: self.broker.tick()
            return (self.root/'launch.request').exists()
        self.until(ready)
        self.assertEqual(json.loads((self.root/'launch.request').read_text()), {'workspace':99,'count':1})
        # Only the fake host can start the lasting GUI. Its handle is always reaped.
        self.gui = subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        self.addCleanup(self.stop, self.gui)
        (self.root/'launch.accepted').touch()
        self.until(lambda:(self.root/'finite.pids').exists())
        return [int(value) for value in (self.root/'finite.pids').read_text().split()]

    @staticmethod
    def stop(process):
        if process.poll() is None: process.kill()
        process.wait(timeout=3)
        for stream in (process.stdin,process.stdout,process.stderr):
            if stream: stream.close()

    def runner(self, request):
        process = subprocess.Popen([sys.executable,str(self.tree/'shell/scripts/widgets/action.py'),'--workflow',str(os.getpid())],
            env=self.environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(self.stop,process)
        process.stdin.write(json.dumps(request)+'\n'); process.stdin.flush()
        return process

    def test_old_consumer_route_hide_kills_after_gui_handoff_before_placement(self):
        self.subscribe(old_route=True)
        self.broker.handle(dict(requestId=2,op='action',consumerId='source',generation=1,
            action='activate',payload={'button':'right'},hostContext=CONTEXT))
        pids = self.handoff(tick=True)
        self.broker.unsubscribe('source')
        self.until(lambda:not any(self.live(pid) for pid in pids))
        (self.root/'postlaunch.release').touch()
        self.assertFalse((self.root/'postlaunch.done').exists())
        self.assertFalse((self.root/'effects').exists())
        self.assertIsNone(self.gui.poll())
        self.assertFalse(self.broker.consumers)
        self.assertIsNone(self.broker.wait_seconds())

    def test_application_workflow_completes_once_with_producer_unsubscribed(self):
        for topic in ['todo','calendar']:
            with self.subTest(topic=topic):
                request = self.subscribe(topic)
                # Production host transfers ownership before writing the runner request.
                self.broker.unsubscribe('source')
                process = self.runner(request)
                pids = self.handoff()
                (self.root/'postlaunch.release').touch()
                output,error = process.communicate(timeout=5)
                self.assertEqual(process.returncode,0,error)
                reply = json.loads(output)
                self.assertTrue(reply['ok'],reply)
                self.assertEqual(reply['placementVerified'],topic == 'todo')
                self.assertEqual((self.root/'postlaunch.done').read_text(),'once')
                self.assertEqual((self.root/'calendar.refresh').exists(),topic == 'calendar')
                self.assertFalse(self.broker.consumers)
                self.assertIsNone(self.broker.wait_seconds())
                self.until(lambda:not any(self.live(pid) for pid in pids))
                self.assertIsNone(self.gui.poll())
                self.stop(self.gui)
                for name in ['launch.request','launch.accepted','postlaunch.release','postlaunch.done',
                             'effects','calendar.refresh','focused.one','finite.pids']:
                    (self.root/name).unlink(missing_ok=True)

    def test_explicit_runner_cancel_and_timeout_kill_whole_finite_group_gui_survives(self):
        for mode in ['cancel','timeout']:
            with self.subTest(mode=mode):
                process=self.runner(self.subscribe(timeout=.5 if mode == 'timeout' else 10))
                self.broker.unsubscribe('source')
                pids=self.handoff()
                if mode == 'cancel': process.terminate()
                output,error=process.communicate(timeout=5)
                if mode == 'timeout':
                    self.assertEqual(json.loads(output)['code'],'timeout')
                self.until(lambda:not any(self.live(pid) for pid in pids))
                self.assertFalse((self.root/'postlaunch.done').exists())
                self.assertIsNone(self.gui.poll())
                self.stop(self.gui)
                for name in ['launch.request','launch.accepted','finite.pids']:
                    (self.root/name).unlink(missing_ok=True)

    def test_application_shutdown_kills_runner_and_whole_finite_group(self):
        request=self.subscribe()
        self.broker.unsubscribe('source')
        environment=dict(self.environment,SYNTHETIC_REQUEST=json.dumps(request),
            SYNTHETIC_RUNNER=str(self.tree/'shell/scripts/widgets/action.py'))
        host_source = """import json,os,subprocess,sys,time
from pathlib import Path
child=subprocess.Popen([sys.executable,os.environ['SYNTHETIC_RUNNER'],'--workflow',str(os.getpid())],
    stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
child.stdin.write(os.environ['SYNTHETIC_REQUEST']+'\\n'); child.stdin.flush()
Path(os.environ['SYNTHETIC_ROOT'],'runner.pid').write_text(str(child.pid))
child.wait()
"""
        host=subprocess.Popen([sys.executable,'-c',host_source],env=environment,
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop,host)
        pids=self.handoff()
        runner_pid=int((self.root/'runner.pid').read_text())
        host.terminate(); host.wait(timeout=3)
        self.until(lambda:not any(self.live(pid) for pid in [runner_pid,*pids]))
        self.assertFalse((self.root/'postlaunch.done').exists())
        self.assertIsNone(self.gui.poll())

    def test_shutdown_before_guard_under_subreaper_rejects_buffered_request(self):
        request = self.subscribe()
        self.broker.unsubscribe('source')
        gate = self.root/'startup'
        gate.mkdir()
        (gate/'sitecustomize.py').write_text('''import os,time
from pathlib import Path
root=Path(os.environ['SYNTHETIC_ROOT'])
(root/'startup.gated').touch()
deadline=time.monotonic()+4
while not (root/'startup.release').exists() and time.monotonic()<deadline: time.sleep(.002)
''')
        environment = dict(self.environment, SYNTHETIC_REQUEST=json.dumps(request),
            SYNTHETIC_RUNNER=str(self.tree/'shell/scripts/widgets/action.py'), SYNTHETIC_GATE=str(gate))
        # A separate owned supervisor becomes a subreaper, so this test does not
        # change adoption behaviour for the other tests or the agent process.
        supervisor = r'''
import ctypes,json,os,signal,subprocess,sys,time
from pathlib import Path
assert ctypes.CDLL(None).prctl(36,1,0,0,0)==0
root=Path(os.environ['SYNTHETIC_ROOT'])
def until(check):
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        value=check()
        if value: return value
        time.sleep(.003)
    raise AssertionError('Subreaper barrier failed')
host_source = """import os,subprocess,sys
from pathlib import Path
environment=dict(os.environ,PYTHONPATH=os.environ['SYNTHETIC_GATE'])
child=subprocess.Popen([sys.executable,os.environ['SYNTHETIC_RUNNER'],'--workflow',str(os.getpid())],
    env=environment,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
child.stdin.write(os.environ['SYNTHETIC_REQUEST']+'\\n');child.stdin.flush()
Path(os.environ['SYNTHETIC_ROOT'],'runner.pid').write_text(str(child.pid))
child.wait()
"""
host=subprocess.Popen([sys.executable,'-c',host_source])
runner=None
try:
    until(lambda:(root/'startup.gated').exists() and (root/'runner.pid').exists())
    runner=int((root/'runner.pid').read_text())
    host.terminate();host.wait(timeout=2)
    assert f'PPid:\t{os.getpid()}\n' in Path(f'/proc/{runner}/status').read_text()
    (root/'startup.release').touch()
    exited=until(lambda:os.waitpid(runner,os.WNOHANG)[0])
    assert exited==runner
    runner=None
    assert not (root/'launch.request').exists(), 'Workflow launched after application shutdown'
finally:
    if host.poll() is None: host.kill()
    host.wait(timeout=2)
    if runner:
        try:os.kill(runner,signal.SIGKILL)
        except ProcessLookupError:pass
        os.waitpid(runner,0)
'''
        result = subprocess.run([sys.executable, '-c', supervisor], env=environment,
            capture_output=True, text=True, timeout=9)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root/'launch.request').exists())

    def test_paused_broker_acknowledgement_gates_mutation_until_producer_is_dead(self):
        request = self.subscribe()
        self.broker.unsubscribe('source')
        marker = self.root/'producer.pid'
        request['widget']['settings']['command'] = [sys.executable, '-c',
            f'import os,time; from pathlib import Path; Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)']
        environment = self.supervision.environment(base=self.environment, PYTHONPATH=str(ROOT/'widgets/lib'))
        broker = subprocess.Popen([sys.executable,'-m','blox_widgets.broker'],env=environment,
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.addCleanup(self.stop,broker)
        def send(value):
            broker.stdin.write((json.dumps(value)+'\n').encode());broker.stdin.flush()
        send(dict(requestId=1,op='subscribe',consumerId='source',generation=1,
            provider='command',options=request['widget']['settings']))
        self.until(lambda:marker.exists() and marker.read_text())
        producer = int(marker.read_text())
        runner = subprocess.Popen([sys.executable,str(self.tree/'shell/scripts/widgets/action.py'),
            '--workflow',str(os.getpid())],env=self.environment,
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(self.stop,runner)
        os.kill(broker.pid,signal.SIGSTOP)
        try:
            send(dict(requestId=2,op='unsubscribe',consumerId='source'))
            time.sleep(.1)
            self.assertTrue(self.live(producer))
            self.assertFalse((self.root/'launch.request').exists())
            self.assertIsNone(runner.poll())
        finally:
            os.kill(broker.pid,signal.SIGCONT)
        os.set_blocking(broker.stdout.fileno(),False)
        received = bytearray()
        def acknowledged():
            try: received.extend(os.read(broker.stdout.fileno(),65536))
            except BlockingIOError: pass
            return any(json.loads(line).get('requestId') == 2 and json.loads(line).get('ok') is True
                for line in bytes(received).split(b'\n')[:-1])
        self.until(acknowledged)
        self.assertFalse(self.live(producer))
        runner.stdin.write(json.dumps(request)+'\n');runner.stdin.flush()
        pids = self.handoff()
        (self.root/'postlaunch.release').touch()
        output,error = runner.communicate(timeout=5)
        self.assertEqual(runner.returncode,0,error)
        self.assertTrue(json.loads(output)['placementVerified'])
        self.until(lambda:not any(self.live(pid) for pid in pids))
        self.assertIsNone(self.gui.poll())
        send(dict(requestId=3,op='shutdown'));broker.wait(timeout=3)

    def test_refresh_failure_is_reported_after_focus_without_retry(self):
        self.environment['SYNTHETIC_FAIL_REFRESH']='1'
        process=self.runner(self.subscribe('calendar'))
        self.broker.unsubscribe('source')
        pids=self.handoff(); (self.root/'postlaunch.release').touch()
        output,error=process.communicate(timeout=5)
        reply=json.loads(output)
        self.assertFalse(reply['ok'])
        self.assertEqual(reply['message'],'Synthetic refresh failure')
        self.assertTrue((self.root/'calendar.refresh').exists())
        self.assertFalse((self.root/'postlaunch.done').exists())
        self.until(lambda:not any(self.live(pid) for pid in pids))
        self.assertIsNone(self.gui.poll())


if __name__ == '__main__': unittest.main()
