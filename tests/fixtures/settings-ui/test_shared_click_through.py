#!/usr/bin/env python3
"""Check the real Blox button's exclusive pointer grab over another action."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='blox-click-through-test-') as directory:
    host = Path(directory)
    shutil.copy2(repo / 'shell/shared/BloxButton.qml', host)
    shutil.copy2(repo / 'shell/shared/BloxToolTip.qml', host)
    shutil.copy2(repo / 'tests/qml/imports/qs/shared/PhosphorIcon.qml', host)
    theme = (repo / 'tests/qml/imports/qs/shared/Theme.qml').read_text()
    (host / 'Theme.qml').write_text(theme)
    (host / 'qmldir').write_text('singleton Theme 1.0 Theme.qml\n')
    shutil.copy2(Path(__file__).with_name('shared-click-through.qml'), host / 'tst_Click.qml')
    shutil.copy2(Path(__file__).with_name('shared-tooltip-overlay.qml'), host / 'tst_Tooltip.qml')
    result = subprocess.run(['/usr/lib/qt6/bin/qmltestrunner', '-input', str(host)],
        env={**os.environ, 'QT_QPA_PLATFORM': 'offscreen'})
    raise SystemExit(result.returncode)
