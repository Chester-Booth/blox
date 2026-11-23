"""Application boundaries with synthetic profiles, processes and compositor handoffs."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ownership_fixture import SupervisionFixture
from unittest.mock import Mock, patch

from blox_widgets.action_context import CONTEXT_ENV, ContextUnavailable, capture_context, helper_context
from blox_widgets.broker import Broker
from blox_widgets.command import CommandOutput, OwnedInvocation
from blox_widgets.first_party import todo_calendar_profile
from blox_widgets.model import default_widget, validate_profile, ValidationError

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('application_action', ROOT / 'shell/scripts/widgets/action.py')
action = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(action)
CONTEXT = {'outputName': 'DP-2', 'workspace': {'id': 4, 'name': '4', 'special': False}}


class ApplicationIntegrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='blox-application-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.supervision = SupervisionFixture().start()
        self.addCleanup(self.supervision.close)

    def until(self, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(.003)
        self.fail('Owned fixture did not finish')

    def request(self):
        widget = default_widget('command', 'sample', {'command': ['producer'], 'actions': {
            'left': {'kind': 'launch', 'command': ['current-app', 'literal ; $(arg)', 'two words']}, 'right': None}})
        return {'widget': widget, 'action': 'activate', 'payload': {'button': 'left'},
                'identity': {'widgetId': 'sample', 'consumerId': 'host-4', 'generation': 7, 'button': 'left'},
                'hostContext': copy.deepcopy(CONTEXT)}

    def test_identity_resolves_only_current_enabled_launch_binding(self):
        request = self.request()
        launcher = Mock(return_value=0)
        output = io.StringIO()
        self.assertEqual(action.main(io.BytesIO(json.dumps(request).encode()), output, launcher), 0)
        launcher.assert_called_once_with(['current-app', 'literal ; $(arg)', 'two words'], 4)
        request['widget']['settings']['actions']['left']['command'] = ['changed-app']
        self.assertEqual(action.prepare_action(request), (['changed-app'], 4))
        for mutate in (
            lambda r: r['widget'].update(enabled=False),
            lambda r: r['widget']['settings']['actions'].update(left=None),
            lambda r: r['payload'].update(command=['forged']),
            lambda r: r['identity'].update(generation=True),
            lambda r: r['identity'].update(widgetId='other'),
            lambda r: r['identity'].update(button='right'),
            lambda r: r['widget']['settings']['actions'].update(left={
                'kind':'run', 'command':['finite'], 'environment':{}, 'workingDirectory':'', 'timeoutSeconds':5}),
        ):
            bad = self.request(); mutate(bad)
            with self.subTest(request=bad), self.assertRaises(ValueError):
                action.prepare_action(bad)

    def test_missing_named_special_or_forged_context_never_launches(self):
        for context in (None, {}, {**CONTEXT, 'command':['evil']},
                        {'outputName':'DP-2', 'workspace':{'id':4,'name':'named','special':False}},
                        {'outputName':'DP-2', 'workspace':{'id':-99,'name':'notes','special':True}},
                        {'outputName':'', 'workspace':CONTEXT['workspace']},
                        {'outputName':'DP-2', 'workspace':{'id':True,'name':'1','special':False}}):
            request = self.request(); request['hostContext'] = context
            launcher = Mock(); output = io.StringIO()
            self.assertEqual(action.main(io.BytesIO(json.dumps(request).encode()), output, launcher), 1)
            launcher.assert_not_called()
            if context and context.get('workspace', {}).get('name') in ('named','notes'):
                self.assertEqual(json.loads(output.getvalue())['code'], 'unavailable')

    def test_uncertain_command_launch_is_attempted_once(self):
        launcher = Mock(side_effect=subprocess.TimeoutExpired(['fake-hyprctl'], 5))
        output = io.StringIO()
        self.assertEqual(action.main(io.BytesIO(json.dumps(self.request()).encode()), output, launcher), 1)
        self.assertEqual(json.loads(output.getvalue())['code'], 'timeout')
        launcher.assert_called_once()

    def test_context_copy_and_reserved_environment_are_separate_from_settings(self):
        context = copy.deepcopy(CONTEXT)
        captured = capture_context(context); context['workspace']['id'] = 99
        self.assertEqual(captured, CONTEXT)
        self.assertEqual(json.loads(helper_context(captured)), {'workspaceId':4})
        for settings in ({'environment': {CONTEXT_ENV:'forged'}}, {'actions':{'left': {
            'kind':'run','command':['finite'],'environment':{CONTEXT_ENV:'forged'},
            'workingDirectory':'','timeoutSeconds':5}, 'right':None}}):
            with self.assertRaises(ValidationError):
                default_widget('command','sample', {'command':['producer'], **settings})
        options = {'command':[sys.executable,'-c', f'import os; print(os.environ.get({CONTEXT_ENV!r}, "absent"))'],
                   'environment':{}, 'workingDirectory':'', 'timeoutSeconds':3}
        with patch.dict(os.environ, {CONTEXT_ENV:'forged inherited'}):
            producer = OwnedInvocation(options); self.addCleanup(producer.close)
            self.assertEqual(self.until(lambda: producer.sample(time.monotonic()))['text'], 'absent')
            owned = OwnedInvocation(options, trusted_context=captured); self.addCleanup(owned.close)
            self.assertEqual(json.loads(self.until(lambda: owned.sample(time.monotonic()))['text']), {'workspaceId':4})

    def test_broker_context_is_generation_bound_and_not_retained_for_refresh(self):
        marker = self.root/'action-context'
        run = {'kind':'run','command':[sys.executable,'-c',
            f'import os; from pathlib import Path; Path({str(marker)!r}).write_text(os.environ.get({CONTEXT_ENV!r},"absent"))'],
            'environment':{}, 'workingDirectory':'', 'timeoutSeconds':3}
        settings = default_widget('command','sample', {'command':[sys.executable,'-c',
            f'import os; print(os.environ.get({CONTEXT_ENV!r}, "absent"))'], 'actions':{'left':run,'right':None}})['settings']
        output = []; broker = Broker(output.append); self.addCleanup(broker.close)
        broker.handle({'requestId':1,'op':'subscribe','consumerId':'host','provider':'command','options':settings,'generation':7})
        request = {'requestId':2,'op':'action','consumerId':'host','generation':6,'action':'activate',
                   'payload':{'button':'left'},'hostContext':copy.deepcopy(CONTEXT)}
        broker.handle(request); self.assertIn('error',output[-1]); self.assertFalse(marker.exists())
        request['generation']=7
        unavailable=copy.deepcopy(request); unavailable['hostContext']['workspace']['name']='named'
        broker.handle(unavailable)
        self.assertEqual(output[-1]['error']['code'],'unavailable')
        self.assertEqual((output[-1]['consumerId'],output[-1]['generation'],output[-1]['op']),('host',7,'action'))
        self.assertFalse(marker.exists())
        broker.handle(request); self.assertEqual(output[-1]['result']['code'],'accepted')
        request['hostContext']['workspace']['id']=99
        group = broker.groups[broker.consumers['host']]; session = group.provider
        self.until(lambda: session.sample(time.monotonic()))
        self.assertEqual(json.loads(marker.read_text()), {'workspaceId':4})
        self.assertEqual(self.until(lambda: session.sample(time.monotonic()))['text'], 'absent')
        request['payload']['environment']={CONTEXT_ENV:'forged'}
        broker.handle(request); self.assertIn('error',output[-1])
        self.assertEqual(session.last_success,'absent')

    def test_unavailable_run_context_keeps_existing_producer_owned_and_unchanged(self):
        run = {'kind':'run','command':['never-execute'], 'environment':{}, 'workingDirectory':'', 'timeoutSeconds':3}
        session = CommandOutput(default_widget('command','sample', {
            'command':[sys.executable,'-c','import time; time.sleep(60)'],
            'actions':{'left':run,'right':None}})['settings'])
        self.addCleanup(session.close)
        self.assertIsNone(session.sample(time.monotonic()))
        invocation = session.invocation; process = session.process
        invalid = {'outputName':'DP-2','workspace':{'id':4,'name':'named','special':False}}
        with self.assertRaises(ContextUnavailable):
            session.action('activate',{'button':'left'},trusted_context=invalid)
        self.assertIs(session.invocation,invocation); self.assertIs(session.process,process)
        self.assertIsNone(process.poll()); self.assertIsNone(session.action_invocation)
        self.assertEqual(session.action_status['state'],'idle')

    def test_fake_compositor_handoff_survives_finite_group_cleanup(self):
        # The server models the compositor, outside the finite action's group.
        endpoint = self.root/'compositor.sock'
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(endpoint)); server.listen(1); server.settimeout(4)
        self.addCleanup(server.close)
        applications = []; expressions = []; failures = []
        def compositor():
            try:
                connection, _ = server.accept()
                with connection:
                    expressions.append(connection.recv(65536).decode())
                    applications.append(subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],
                        start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    connection.sendall(b'accepted')
            except BaseException as error: failures.append(error)
        worker = threading.Thread(target=compositor, daemon=True); worker.start()
        def cleanup():
            for child in applications:
                child.kill(); child.wait(timeout=2)
        self.addCleanup(cleanup)
        marker = self.root/'finite-pid'
        source = f"""
import os,socket,subprocess,sys,types
from pathlib import Path
sys.path.insert(0,{str(ROOT/'shell/scripts/launcher')!r})
# Only pure launcher quoting is under test. No GUI library or desktop entry lookup.
gi=types.ModuleType('gi'); gi.require_version=lambda *args: None
repository=types.ModuleType('gi.repository'); repository.GioUnix=None
sys.modules.update({{'gi':gi,'gi.repository':repository}})
import desktop_exec
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],
    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
Path({str(marker)!r}).write_text(str(child.pid))
def dispatch(argv, **kwargs):
    assert argv[:2] == ['hyprctl','eval']
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
        connection.connect({str(endpoint)!r}); connection.sendall(argv[2].encode()); assert connection.recv(20)==b'accepted'
    return types.SimpleNamespace(returncode=0)
desktop_exec.subprocess.run=dispatch
assert desktop_exec.launch_detached(['fake-gui','literal ; $(data)'],None,dict(os.environ),workspace_id=4,launch_id='fake-gui',timeout_seconds=2)==0
print('finished')
"""
        owned = OwnedInvocation({'command':[sys.executable,'-c',source], 'workingDirectory':'',
                                 'environment':{},'timeoutSeconds':4}, trusted_context=CONTEXT)
        self.addCleanup(owned.close)
        result = self.until(lambda: owned.sample(time.monotonic()))
        self.assertEqual(result['error'],''); self.assertEqual(result['text'],'finished')
        worker.join(timeout=5); self.assertFalse(worker.is_alive()); self.assertFalse(failures)
        self.assertEqual(len(applications),1); self.assertIsNone(applications[0].poll())
        finite_pid = int(marker.read_text())
        def dead():
            try: return Path(f'/proc/{finite_pid}/stat').read_text().split(') ')[1][0] == 'Z'
            except FileNotFoundError: return True
        self.until(dead)
        self.assertIn('workspace = "4 silent"',expressions[0])
        self.assertIn("'literal ; $(data)'",expressions[0])
        self.assertIn('-u BLOX_WIDGET_ACTION_CONTEXT',expressions[0])

    def test_new_profile_builder_and_fixture_have_all_four_exact_finite_bindings(self):
        profile = todo_calendar_profile('/fixture/blox/shell/scripts')
        fixture = json.loads((ROOT/'widgets/examples/first-party-actions.profile.json').read_text())
        self.assertEqual(validate_profile(fixture),profile)
        actual = [(widget['id'], button, widget['settings']['actions'][button])
                  for widget in profile['widgets'] for button in ('left','right')]
        for (topic, button, binding), operation, cap in zip(actual, ('next','edit','next','open'),(5,10,120,120)):
            self.assertEqual(binding, {'kind':'run','command':['blox-widget-action',topic,operation],
                                      'environment':{},'workingDirectory':'','timeoutSeconds':cap})
        profile['widgets'][0]['settings']['actions']['left']['command'][0]='changed'
        self.assertEqual(todo_calendar_profile('/fixture/blox/shell/scripts'),fixture)
        with self.assertRaises(ValueError): todo_calendar_profile('relative')

    def test_workflow_import_stays_inside_quickshell_config_root(self):
        controller = ROOT / 'shell/services/WidgetActionController.qml'
        self.assertIn('import "FirstPartyWorkflow.js" as Workflow', controller.read_text())
        shell_copy = controller.parent / 'FirstPartyWorkflow.js'
        widget_copy = ROOT / 'widgets/qml/Blox/Widgets/FirstPartyWorkflow.js'
        self.assertEqual(shell_copy.read_bytes(), widget_copy.read_bytes())
        self.assertTrue(shell_copy.resolve().is_relative_to((ROOT / 'shell').resolve()))

    def test_current_installer_enumerates_wrapper_module_and_launcher_dependencies(self):
        sys.path.insert(0,str(ROOT/'packaging'))
        import install
        pairs = dict((relative,path) for path,relative in install._iter_source_pairs(ROOT))
        required = ['bin/blox-widget-action','shell/scripts/widgets/user_actions.py',
                    'shell/scripts/launcher/desktop_exec.py','widgets/lib/blox_widgets/action_context.py',
                    'shell/scripts/widgets/action.py','widgets/catalogue.json','widgets/schema/profile.schema.json',
                    'shell/services/FirstPartyWorkflow.js','widgets/qml/Blox/Widgets/FirstPartyWorkflow.js']
        required += [relative for relative in pairs if relative.startswith('widgets/lib/blox_widgets/') and relative.endswith('.py')]
        self.assertIn('blox-widget-action',install.INSTALLED_BINS)
        self.assertTrue(os.access(pairs['bin/blox-widget-action'],os.X_OK))
        # Materialise only these enumerated files in an isolated installed-shaped tree.
        # No installer, services or real user directories run here.
        target = self.root/'prefix/share/blox'
        for relative in required:
            destination=target/relative; destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(pairs[relative],destination)
        (self.root/'bin').mkdir()
        wrapper=self.root/'bin/blox-widget-action'; wrapper.symlink_to(target/'bin/blox-widget-action')
        environment={**os.environ,'HOME':str(self.root/'home'),'XDG_STATE_HOME':str(self.root/'state'),
                     'XDG_RUNTIME_DIR':str(self.root/'runtime'),'XDG_CACHE_HOME':str(self.root/'cache')}
        result=subprocess.run([str(wrapper),'todo','next'],env=environment,capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['selectedFile'],str(self.root/'home/Documents/todo/1-todo.md'))
        # Import the actual copied launch dependency. A fake compositor is the only executable it may call.
        source = 'import sys; sys.path.insert(0,sys.argv[1]); import desktop_exec; print("ok")'
        result=subprocess.run([sys.executable,'-c',source,str(target/'shell/scripts/launcher')],
                              env=environment,capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'ok\n')
        # Resolve a complete launch request from the copied model/schema/module tree.
        request=json.dumps(self.request())
        harness = ("import importlib.util,io,json,sys; "
                   "spec=importlib.util.spec_from_file_location('installed_action',sys.argv[1]); "
                   "module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); "
                   "code=module.main(io.BytesIO(sys.argv[2].encode()),launcher=lambda argv,workspace:0); "
                   "raise SystemExit(code)")
        result=subprocess.run([sys.executable,'-I','-c',harness,str(target/'shell/scripts/widgets/action.py'),request],
                              env=environment,capture_output=True,text=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(json.loads(result.stdout)['ok'])


if __name__ == '__main__': unittest.main()
