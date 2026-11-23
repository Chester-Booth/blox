#!/usr/bin/env python3
"""Publish an isolated appearance-only archive through the real import owner."""
import copy, json, os, sys
from pathlib import Path
repo = Path(os.environ['BLOX_TEST_REPO'])
sys.path.insert(0, str(repo))
from shell.scripts.bundle_runtime import run_components
from shell.scripts.settings_document import SettingsDocument
from themes.lib.blox_theme.core import load_theme
from themes.lib.blox_theme.component_bundle import export_components
identifier, accent = sys.argv[1:]
path, source = load_theme('midnight')
source = copy.deepcopy(source)
source.update(id=identifier, name=identifier.title())
source['colours']['accent'] = accent
owner = SettingsDocument()
archive = Path(os.environ['XDG_STATE_HOME']) / 'opening-proof.zip'
archive.unlink(missing_ok=True)
export_components(source, owner.get().data, archive, 'custom', {'theme-metadata', 'appearance'}, source_path=path)
review = run_components('inspect', {'theme':'midnight', 'path':str(archive)}, owner)
result = run_components('import', {'theme':'midnight', 'path':str(archive), 'digest':review['digest'],
    'revision':review['settingsRevision'], 'components':['appearance'], 'replace':review['sourceDigest'] is not None,
    'sourceDigest':review['sourceDigest']}, owner)
print(json.dumps(result))
