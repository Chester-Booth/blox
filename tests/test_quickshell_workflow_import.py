"""Exercise workflow imports through Quickshell's real configuration-root mapping."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is required")
class QuickshellWorkflowImportTests(unittest.TestCase):
    def test_application_workflow_import_stays_inside_config_root(self):
        controller = (ROOT / "shell/services/WidgetActionController.qml").read_text()
        imports = re.findall(r'^import "[^"]+" as Workflow$', controller, re.MULTILINE)
        self.assertEqual(len(imports), 1)
        with tempfile.TemporaryDirectory(prefix="blox-workflow-root-") as directory:
            base = Path(directory)
            shell = base / "shell"
            services = shell / "services"
            services.mkdir(parents=True)
            # Keep the sibling present, as in the real package. Quickshell must
            # still reject imports escaping its selected configuration root.
            sibling = base / "widgets/qml/Blox/Widgets"
            sibling.mkdir(parents=True)
            for target in (services, sibling):
                shutil.copyfile(ROOT / "shell/services/FirstPartyWorkflow.js",
                                target / "FirstPartyWorkflow.js")
            (services / "Probe.qml").write_text('''import QtQuick
import Quickshell
''' + imports[0] + '''
Scope {
    Component.onCompleted: {
        const binding = {kind: "run", command: ["blox-widget-action", "todo", "edit"], timeoutSeconds: 120};
        if (Workflow.operation(binding) !== "todo" || Workflow.cap(binding) !== 10)
            throw new Error("Workflow import returned the wrong implementation");
        console.log("WORKFLOW_ROOT_OK");
    }
    Timer { interval: 20; running: true; onTriggered: Qt.quit() }
}
''')
            (shell / "shell.qml").write_text('import Quickshell\nimport "services"\nScope { Probe {} }\n')
            env = dict(os.environ, QT_QPA_PLATFORM="offscreen",
                       QT_QUICK_BACKEND="software", QT_QPA_PLATFORMTHEME="generic",
                       QS_DISABLE_CRASH_HANDLER="1")
            for name in ("WAYLAND_DISPLAY", "DISPLAY", "QS_CONFIG_PATH", "QS_CONFIG_NAME", "QS_MANIFEST"):
                env.pop(name, None)
            result = subprocess.run(["quickshell", "--no-color", "--path", str(shell)],
                                    env=env, capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("WORKFLOW_ROOT_OK", output)
            self.assertNotIn("qs-blackhole", output)


if __name__ == "__main__":
    unittest.main()
