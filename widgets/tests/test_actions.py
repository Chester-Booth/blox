"""Native action authorisation without invoking an opener, app or compositor."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import Mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("widget_action", ROOT / "shell/scripts/widgets/action.py")
actions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(actions)
from blox_widgets.model import default_widget


class WidgetActionTests(unittest.TestCase):
    def request(self, kind, settings, action, payload):
        return {"widget": default_widget(kind, "test-widget", settings), "action": action, "payload": payload, "workspaceId": 4}

    def test_only_exact_fixed_gui_operations_get_application_lifetime_and_caps(self):
        for topic, operation, cap in [('todo','edit',10),('calendar','open',120)]:
            binding={'kind':'run','command':['blox-widget-action',topic,operation],
                'workingDirectory':'','environment':{},'timeoutSeconds':120}
            request=self.request('command',{'command':['producer'],'actions':{'left':None,'right':binding}},
                'activate',{'button':'right'})
            request['identity']={'widgetId':'test-widget','consumerId':'consumer','generation':7,'button':'right'}
            request['hostContext']={'outputName':'SYNTHETIC','workspace':{'id':99,'name':'99','special':False}}
            prepared,context=actions.prepare_action(request,workflow=True)
            self.assertEqual(prepared['timeoutSeconds'],cap)
            self.assertEqual(prepared['command'][1:], [str(ROOT/'shell/scripts/widgets/user_actions.py'),topic,operation])
            self.assertEqual(context,request['hostContext'])
            binding=request['widget']['settings']['actions']['right']
            for command in [['blox-widget-action',topic,'next'],['blox-widget-action',topic,operation,'extra'],
                            ['/untrusted/blox-widget-action',topic,operation],['arbitrary']]:
                binding['command']=command
                with self.assertRaises(ValueError): actions.prepare_action(request,workflow=True)

    def test_shortcut_uses_configured_argv_and_captured_workspace(self):
        command = ["example", "a space", "$(touch /bad)", "; echo bad"]
        request = self.request("shortcuts", {"items": [{"id": "go", "label": "Go", "command": command}]},
                               "launch", {"id": "go", "command": ["untrusted"]})
        launcher = Mock(return_value=0)
        output = io.StringIO()
        self.assertEqual(actions.main(io.BytesIO(json.dumps(request).encode()), output, launcher), 0)
        launcher.assert_called_once_with(command, 4)
        self.assertTrue(json.loads(output.getvalue())["ok"])
        request["payload"]["id"] = "deleted"
        with self.assertRaises(ValueError):
            actions.prepare_action(request)

    def test_files_must_be_current_visible_children_inside_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "files"
            directory.mkdir()
            normal = directory / "- a space.txt"
            normal.write_text("content")
            folder = directory / "folder"
            folder.mkdir()
            hidden = directory / ".hidden"
            hidden.write_text("hidden")
            outside = root / "outside.txt"
            outside.write_text("outside")
            escaped = directory / "escape.txt"
            escaped.symlink_to(outside)
            settings = {"directory": str(directory), "showHidden": False, "maxEntries": 80}
            self.assertEqual(actions.file_command(settings, str(normal)), ["xdg-open", normal.as_uri()])
            self.assertEqual(actions.file_command(settings, str(folder)), ["xdg-open", folder.as_uri()])
            for denied in (hidden, outside, escaped, directory / "missing"):
                with self.subTest(path=denied), self.assertRaises(ValueError):
                    actions.file_command(settings, str(denied))
            normal.unlink()
            with self.assertRaises(ValueError):
                actions.file_command(settings, str(normal))

    def test_files_never_execute_programs_or_desktop_entries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            program = root / "program"
            program.write_text("executable")
            program.chmod(0o755)
            desktop = root / "app.desktop"
            desktop.write_text("[Desktop Entry]\nExec=bad")
            settings = {"directory": str(root), "showHidden": False, "maxEntries": 80}
            for denied in (program, desktop):
                with self.subTest(path=denied), self.assertRaises(ValueError):
                    actions.file_command(settings, str(denied))

    def test_disabled_invalid_and_oversized_requests_do_not_launch(self):
        request = self.request("shortcuts", {"items": [{"id": "go", "label": "Go", "command": ["example"]}]}, "launch", {"id": "go"})
        request["widget"]["enabled"] = False
        launcher = Mock()
        for raw in (json.dumps(request).encode(), b"{", b"x" * (actions.MAX_INPUT_BYTES + 1)):
            output = io.StringIO()
            self.assertEqual(actions.main(io.BytesIO(raw), output, launcher), 1)
            self.assertFalse(json.loads(output.getvalue())["ok"])
        launcher.assert_not_called()

    def test_timeout_never_retries_an_uncertain_launch(self):
        request = self.request("shortcuts", {"items": [{"id": "go", "label": "Go", "command": ["example"]}]}, "launch", {"id": "go"})
        launcher = Mock(side_effect=subprocess.TimeoutExpired(["hyprctl"], 5))
        output = io.StringIO()
        self.assertEqual(actions.main(io.BytesIO(json.dumps(request).encode()), output, launcher), 1)
        self.assertEqual(json.loads(output.getvalue())["code"], "timeout")
        launcher.assert_called_once()


if __name__ == "__main__":
    unittest.main()
