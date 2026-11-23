"""Exercise helper entrypoints with only the installed layout available."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "shell/scripts"


class InstalledHelperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "installed prefix/share/blox/shell/scripts"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {**os.environ, "HOME": str(self.root / "home"),
                            "XDG_CONFIG_HOME": str(self.root / "config"),
                            "XDG_CACHE_HOME": str(self.root / "cache"),
                            "PATH": str(self.bin) + ":" + os.environ["PATH"]}
        for name in ("QUICKSHELL_IPC_PID", "QUICKSHELL_CONFIG_PATH", "BLOX_SHELL_DIR"):
            self.environment.pop(name, None)

    def executable(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    def install(self, relative):
        destination = self.scripts / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE / relative, destination)
        return destination

    def test_clipboard_ingest_reaches_installed_backend(self):
        script = self.install("launcher/clipboard-watch-ingest")
        self.executable(self.scripts / "launcher/clipboardctl.py", "#!/usr/bin/env python3\n"
                        "import json,sys\nprint(json.dumps([sys.argv[1:], sys.stdin.read()]))\n")
        self.environment["BLOX_CLIPBOARD_MIME"] = "text/plain"
        result = subprocess.run([str(script)], input="clipboard fixture", text=True,
                                capture_output=True, env=self.environment, check=True)
        self.assertEqual([["ingest", "--mime", "text/plain"], "clipboard fixture"],
                         json.loads(result.stdout))

    def test_display_actions_use_the_installed_shared_owner(self):
        self.install("bloxctl.py")
        self.install("ipc.sh")
        self.environment["QUICKSHELL_IPC_PID"] = "23456"
        self.executable(self.bin / "quickshell", "#!/usr/bin/env python3\nimport json,os,sys\n"
                        "code=os.environ.get('FIXTURE_OWNER_CODE','ok')\n"
                        "print(json.dumps({'version':1,'ok':code=='ok','code':code,'message':'','data':{'arguments':sys.argv[1:]}}))\n")
        marker = self.root / "native-mutation"
        for name in ("pkill", "hyprsunset"):
            self.executable(self.bin / name, '#!/bin/sh\ntouch "' + str(marker) + '"\nexit 99\n')
        for relative, arguments, operation, value in (("display/hyprsunset-toggle.sh", [], "toggle", ""),
                                                       ("display/blue-light-mode.sh", ["off"], "set", "off")):
            with self.subTest(script=relative):
                result = subprocess.run([str(self.install(relative)), *arguments], text=True,
                                        capture_output=True, env=self.environment, check=True)
                receipt = json.loads(result.stdout)
                self.assertTrue(receipt["ok"])
                self.assertEqual(["ipc", "--pid", "23456", "call", "blox", "nightLight", operation, value], receipt["data"]["arguments"])
                self.assertFalse(marker.exists())
        self.environment["FIXTURE_OWNER_CODE"] = "permission-denied"
        result = subprocess.run([str(self.scripts / "display/blue-light-mode.sh"), "on"], text=True,
                                capture_output=True, env=self.environment)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(json.loads(result.stdout)["code"], "permission-denied")
        self.assertFalse(marker.exists())

    def test_registry_cannot_replace_authenticated_discovery(self):
        script = self.install("ipc.sh")
        target = self.scripts.parents[1] / "widgets/lib/blox_widgets"
        shutil.copytree(SOURCE.parents[1] / "widgets/lib/blox_widgets", target,
                        ignore=shutil.ignore_patterns('__pycache__'))
        self.executable(self.bin / "systemctl", '#!/bin/sh\nprintf "MainPID=0\\n"\n')
        marker = self.root / "unverified-qt"
        self.executable(self.bin / "quickshell", '#!/bin/sh\ntouch "' + str(marker) + '"\nexit 99\n')
        result = subprocess.run([str(script), "fixture", "call"], text=True,
                                capture_output=True, env=self.environment)
        self.assertEqual(result.returncode, 3)
        self.assertFalse(marker.exists())
