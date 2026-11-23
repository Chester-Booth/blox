#!/usr/bin/env python3
"""Review and complete component bundles without activating any target."""
from __future__ import annotations
import copy
import base64
import mimetypes
import hashlib
import json
import os
import tempfile
import zipfile
import sys
from pathlib import Path

PRODUCT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PRODUCT_ROOT))
from shell.scripts.settings_document import SettingsDocument
from themes.lib.blox_theme import component_bundle as bundles
from themes.lib.blox_theme.core import load_theme, user_theme_library, canonical_json
from themes.lib.blox_theme.generators import save_theme_source
from themes.lib.blox_theme import portability
from themes.lib.blox_theme.core import resolve_wallpaper_path

ROWS = [
    ('appearance', 'Core appearance', 'Colours, fonts, window and cursor appearance'),
    ('wallpaper', 'Wallpaper', 'Theme wallpaper'),
    ('bar', 'Bar layout and contents', 'Bar position, style and items'),
    ('osd', 'OSD', 'Volume, brightness and other indicators'),
    ('notifications', 'Notifications', 'Position and appearance'),
    ('widgets', 'Widgets', 'Widget profiles and layout'),
    ('targets', 'Application targets', 'Saved target enablement and apply modes'),
    ('target-appearance', 'Target appearance', 'Application-specific theme values'),
    ('binds', 'Binds', 'Blox-owned Hyprland Lua settings'),
    ('autostart', 'Autostart', 'Persistent autostart entries'),
    ('power', 'Power policy', 'AC and battery policy'),
    ('monitors', 'Monitors', 'Saved display layout')]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_companion(path, data):
    """Publish dormant bundle data beside its theme without following a symlink."""
    if path.is_symlink() or path.exists() and not path.is_file():
        raise ValueError('Unsafe dormant component destination')
    fd, name = tempfile.mkstemp(prefix='.blox-components-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def scripts_for_ui(records):
    return [{**record, 'id': record['path'], 'preview': record['contents'],
             'viewMode': 'expand' if len(record['contents'].splitlines()) > 4 else 'plain',
             'reason': record['path'] + ' · ' + str(record['size']) + ' bytes · SHA-256 ' + record['sha256']}
            for record in records]


def run(action, request, document=None):
    """Convert old theme sources for review without publishing or activating them."""
    if action not in ('inspect', 'import'):
        return run_components(action, request, document)
    source = Path(request['path']).expanduser()
    if source.is_symlink() or not source.is_file():
        raise ValueError('Import source is not a regular file')
    reviewed_digest = digest(source)
    if action == 'import' and reviewed_digest != request['digest']:
        raise ValueError('Bundle or Settings changed since review. Review the bundle again.')
    if zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            # The full component reader still checks sizes, names and member digests.
            info = archive.getinfo('manifest.json')
            if info.file_size > portability.MAX_MEMBER_BYTES:
                raise ValueError('Oversized bundle manifest')
            version = json.loads(archive.read(info)).get('bundleVersion')
        if version == bundles.VERSION:
            return run_components(action, request, document)
        imported, wallpaper_data, wallpaper_name, _ = portability._load_bundle(source)
        with zipfile.ZipFile(source) as archive:
            supplied_widgets = 'widgets' in json.loads(archive.read('theme.json'))
    else:
        imported, _ = portability._load_loose_json(source)
        supplied_widgets = 'widgets' in json.loads(source.read_text(encoding='utf-8'))
        wallpaper_data = wallpaper_name = None
    with tempfile.TemporaryDirectory(prefix='blox-legacy-review-') as temporary:
        root = Path(temporary)
        selected = {'theme-metadata', 'appearance'}
        if wallpaper_data is not None:
            wallpaper = root / wallpaper_name
            wallpaper.write_bytes(wallpaper_data)
        else:
            wallpaper = resolve_wallpaper_path(imported['wallpaper']['path'], source)
        if wallpaper.is_file() and not wallpaper.is_symlink():
            imported['wallpaper']['path'] = str(wallpaper)
            selected.add('wallpaper')
        normalised = root / 'legacy.blox-theme'
        owner = document or SettingsDocument()
        settings = copy.deepcopy(owner.get().data)
        if supplied_widgets:
            # The explicit source component owns its whole profile, including an empty list.
            settings['widgets'] = copy.deepcopy(imported['widgets'])
            selected.add('widgets')
        bundles.export_components(imported, settings, normalised, 'custom', selected, source_path=source, package_scripts=False)
        converted = {**request, 'path': str(normalised)}
        if action == 'import':
            converted['digest'] = digest(normalised)
        result = run_components(action, converted, owner)
        if action == 'inspect':
            result['digest'] = reviewed_digest
        return result


def run_components(action, request, document=None):
    owner = document or SettingsDocument()
    current = owner.get()
    if not current.ok:
        raise ValueError('Settings read failed: ' + current.code)
    path, theme = load_theme(request['theme'])
    settings = copy.deepcopy(current.data)
    chosen = set(request.get('components', bundles.selection('standard')))
    chosen.add('theme-metadata')
    approvals = request.get('approvals', {})
    if action == 'inspect':
        source = Path(request['path'])
        manifest, components, files = bundles.inspect_components(source)
        imported, _, _ = bundles.import_components(source, theme, settings, user_theme_library(), install_assets=False)
        colours = imported['colours']
        wallpaper = components.get('wallpaper', {}).get('path')
        preview_wallpaper = ''
        if wallpaper in files:
            mime = mimetypes.guess_type(wallpaper)[0] or 'application/octet-stream'
            preview_wallpaper = 'data:' + mime + ';base64,' + base64.b64encode(files[wallpaper]).decode()
        card = {'id': imported['id'], 'name': imported['name'], 'meta': '',
                'wallpaper': preview_wallpaper, 'palette': [colours[key] for key in ('accent', 'success', 'warning', 'foreground')],
                'preview': {'background': colours['background'], 'surface': colours['surface'], 'surfaceAlt': colours['surface_alt'],
                            'foreground': colours['foreground'], 'muted': colours['muted'], 'accent': colours['accent']},
                'previewFont': imported['fonts']['ui'], 'barPosition': imported.get('shell', {}).get('bar', {}).get('position', 'top')}
        metadata = components.get('theme-metadata', {})
        theme_id = metadata.get('id', theme['id'])
        destination = user_theme_library() / 'themes' / (theme_id + '.json')
        # Metadata is validated before it can become a destination name.
        if not isinstance(theme_id, str) or not __import__('re').fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', theme_id):
            raise ValueError('invalid imported theme ID')
        return {'components': manifest['components'], 'name': metadata.get('name', theme['name']),
                'id': theme_id, 'card': card, 'digest': digest(source), 'settingsRevision': current.revision,
                'sourceDigest': digest(destination) if destination.is_file() else None,
                'validation': 'conflict' if destination.exists() else 'valid',
                'scripts': scripts_for_ui(bundles.review_import(source))}
    if action == 'review-export':
        return {'scripts': scripts_for_ui(bundles.review_export(theme, settings, request.get('preset', 'custom'), chosen)),
                'settingsRevision': current.revision, 'themeDigest': digest(path)}
    if action == 'export':
        if current.revision != request['revision'] or digest(path) != request['themeDigest']:
            raise ValueError('Theme or Settings changed since review. Review the bundle again.')
        manifest = bundles.export_components(theme, settings, Path(request['path']), request.get('preset', 'custom'),
                                         chosen, approvals=approvals, source_path=path,
                                         selected_targets=set(request.get("targets", settings["targets"])),
                                         expected_output_digest=digest(Path(request["path"])) if Path(request["path"]).is_file() and not Path(request["path"]).is_symlink() else None)
        return {**manifest, "path": str(Path(request["path"]).expanduser().absolute())}
    if action == 'import':
        source = Path(request['path'])
        if digest(source) != request['digest'] or current.revision != request['revision']:
            raise ValueError('Bundle or Settings changed since review. Review the bundle again.')
        imported, next_settings, dormant = bundles.import_components(source, theme, settings, user_theme_library(), chosen, approvals)
        if request.get('copy'):
            directory = user_theme_library() / 'themes'
            original_id, original_name = imported['id'], imported['name']
            number = 1
            while True:
                suffix = '-copy' if number == 1 else '-copy-' + str(number)
                candidate = original_id + suffix
                destinations = [directory / (candidate + suffix) for suffix in ('.json', '.components.json')]
                if all(not entry.exists() and not entry.is_symlink() for entry in destinations):
                    break
                number += 1
            imported['id'] = candidate
            imported['name'] = original_name + (' copy' if number == 1 else ' copy ' + str(number))
        destination = user_theme_library() / 'themes' / (imported['id'] + '.json')
        previous = destination.read_bytes() if destination.is_file() and not destination.is_symlink() else None
        replace = bool(request.get('replace')) and not request.get('copy')
        dormant_path = destination.with_suffix('.components.json')
        if dormant_path.is_symlink() or dormant_path.exists() and not dormant_path.is_file():
            raise ValueError('Unsafe dormant component destination')
        previous_dormant = dormant_path.read_bytes() if dormant_path.exists() else None
        save_theme_source(imported, destination.parent, replace=replace,
                          expected_sha256=request.get('sourceDigest') if replace else None)
        # The document owner commits all selected sections in one revision.
        updates = {key: value for key, value in next_settings.items() if key not in ('schemaVersion', 'revision') and value != settings[key]}
        try:
            if dormant or previous_dormant is not None:
                write_companion(dormant_path, canonical_json({'manifestVersion': 1, 'dormant': dormant}).encode())
            result = owner.update_sections(updates, request['revision']) if updates else None
            if result is not None and not result.ok and not result.committed:
                raise ValueError('Settings import failed: ' + result.code)
        except Exception:
            if previous_dormant is None:
                dormant_path.unlink(missing_ok=True)
            else:
                write_companion(dormant_path, previous_dormant)
            if previous is None:
                destination.unlink()
            else:
                # Use the same checked writer to restore the replaced source.
                save_theme_source(json.loads(previous), destination.parent, replace=True, expected_sha256=digest(destination))
            raise
        return {'id': imported['id'], 'name': imported['name'], 'path': str(destination), 'revision': result.revision if result else current.revision,
                'dormant': sorted(dormant), 'changedComponents': sorted(updates)}
    raise ValueError('unknown bundle operation')


def main():
    try:
        result = run(sys.argv[1], json.loads(sys.argv[2]))
        print(json.dumps({'version': 1, 'ok': True, 'code': 'ok', 'data': result}))
        return 0
    except Exception as error:
        print(json.dumps({'version': 1, 'ok': False, 'code': 'bundle-error', 'message': str(error), 'data': None}))
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
