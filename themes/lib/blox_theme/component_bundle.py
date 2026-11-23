"""Version 2 component bundles. Review and mutation are separate operations."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import shlex
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

from .core import apply_theme_defaults, canonical_json, repository_root, resolve_wallpaper_path, validate_theme
from .portability import MAX_BUNDLE_BYTES, MAX_MEMBER_BYTES, MAX_TOTAL_BYTES, PortabilityFailure, _zip_info

VERSION = 2
APPEARANCE = ('shape', 'hyprland', 'fonts', 'colours', 'gtk', 'icons', 'cursor', 'terminal', 'overrides')
SETTINGS = ('bar', 'osd', 'notifications', 'widgets', 'targets', 'binds', 'autostart', 'power', 'monitors')
MAX_SCRIPT_BYTES = 1024 * 1024


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _registry() -> dict:
    return json.loads((repository_root() / 'themes/schema/components-v1.json').read_text())


def selection(preset: str, selected: set[str] | None = None, wallpaper: bool = True) -> tuple[str, ...]:
    registry = _registry()
    presets = registry['bundlePresets']
    if preset not in (*presets, 'custom'):
        raise PortabilityFailure(f'unknown bundle preset: {preset}')
    allowed = {entry['id'] for entry in registry['components']} - {'settings-document'}
    chosen = set(presets[preset]) if preset != 'custom' else set()
    if selected is not None:
        chosen = set(selected)
    if not chosen <= allowed:
        raise PortabilityFailure(f'unknown component: {sorted(chosen - allowed)}')
    if not wallpaper:
        chosen.discard('wallpaper')
    if not {'theme-metadata', 'appearance'} <= chosen:
        raise PortabilityFailure('theme metadata and appearance are required')
    return tuple(sorted(chosen))


def _source_components(theme: dict, settings: dict, chosen: tuple[str, ...]) -> dict[str, Any]:
    from shell.scripts.settings_document import SettingsDocument
    SettingsDocument()._validate(settings)
    theme = apply_theme_defaults(theme)
    checked = validate_theme(theme, check_dependencies=False)
    if checked.errors:
        raise PortabilityFailure('invalid theme: ' + '; '.join(checked.errors))
    result: dict[str, Any] = {}
    for name in chosen:
        if name == 'theme-metadata':
            result[name] = {key: theme[key] for key in ('id', 'name', 'variant')}
        elif name == 'appearance':
            result[name] = {key: copy.deepcopy(theme[key]) for key in APPEARANCE if key in theme}
        elif name == 'wallpaper':
            result[name] = copy.deepcopy(theme['wallpaper'])
        elif name == 'target-appearance':
            result[name] = {key: copy.deepcopy(value['overrides']) for key, value in settings['targets'].items() if 'overrides' in value}
        elif name == 'targets':
            result[name] = {key: {part: copy.deepcopy(value[part]) for part in ('enabled', 'styleSet') if part in value} for key, value in settings['targets'].items()}
        else:
            result[name] = copy.deepcopy(settings[name])
    return result


def _references(components: dict) -> list[tuple[dict, str, str, str]]:
    """Yield executable heads, leaving command arguments and non-exec binds alone."""
    refs = []
    profile = components.get('widgets')
    if profile is not None:
        from .core import widget_model
        widget_model().validate_profile(profile)
        for item in profile['widgets']:
            if not item['enabled']:
                continue
            if item['kind'] in ('terminal', 'command'):
                refs.append((item, 'settings.command', item['settings']['command'][0], 'argv'))
                if item['kind'] == 'command':
                    for button, action in item['settings']['actions'].items():
                        if action is not None:
                            refs.append((item, f'settings.actions.{button}.command', action['command'][0], 'argv'))
            elif item['kind'] == 'shortcuts':
                for index, entry in enumerate(item['settings']['items']):
                    refs.append((item, f'settings.items.{index}.command', entry['command'][0], 'argv'))
    for item in components.get('binds', []):
        if item['action'] == 'exec' and item['arguments']:
            refs.append((item, 'arguments', item['arguments'][0], 'argv'))
    for item in components.get('autostart', []):
        refs.append((item, 'argv', item['argv'][0], 'argv'))
    return refs


def _user_script(path: str) -> bool:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute() or path.startswith('assets/'):
        return False
    if candidate.is_relative_to(Path.home()):
        return True
    try:
        return candidate.lstat().st_uid == os.getuid()
    except FileNotFoundError:
        return False


def _read_script(path: str) -> bytes:
    candidate = Path(path)
    if candidate.is_symlink():
        raise PortabilityFailure(f'unsafe script symlink: {path}')
    try:
        fd = os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise PortabilityFailure(f'cannot read script: {path}: {error}') from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > MAX_SCRIPT_BYTES:
            raise PortabilityFailure(f'unsafe script file: {path}')
        data = os.read(fd, MAX_SCRIPT_BYTES + 1)
        if len(data) != info.st_size:
            raise PortabilityFailure(f'script changed while reading: {path}')
        data.decode('utf-8')
        return data
    except UnicodeDecodeError as error:
        raise PortabilityFailure(f'script is not UTF-8 text: {path}') from error
    finally:
        os.close(fd)


def review_export(theme: dict, settings: dict, preset: str, selected: set[str] | None = None,
                  wallpaper: bool = True) -> list[dict]:
    components = _source_components(theme, settings, selection(preset, selected, wallpaper))
    reviews = {}
    for _, _, path, _ in _references(components):
        if _user_script(path):
            data = _read_script(path)
            reviews[path] = {'name': Path(path).name, 'path': path, 'size': len(data),
                             'sha256': _sha(data), 'contents': data.decode('utf-8')}
    return list(reviews.values())


def _reference_container(item: dict, field: str) -> tuple[dict, str]:
    parts = field.split('.')
    node = item
    for part in parts[:-1]:
        node = node[int(part)] if isinstance(node, list) else node[part]
    return node, parts[-1]


def _replace_reference(item: dict, field: str, old: str, new: str, kind: str) -> None:
    target, key = _reference_container(item, field)
    if kind == 'argv':
        target[key][0] = new
    elif kind == 'shell':
        parts = shlex.split(target[key]); parts[0] = new
        target[key] = shlex.join(parts)
    else:
        target[key] = new


def _disable(item: dict, field: str, kind: str) -> None:
    item['enabled'] = False
    # Widget command arrays are required configuration. Retain them for review.
    if 'kind' in item:
        return
    target, key = _reference_container(item, field)
    if kind == 'argv':
        target[key] = ['/usr/bin/false']
    elif kind == 'shell':
        target[key] = ''
    else:
        target[key] = 'disabled'


def _widget_reviews(profile: dict) -> list[dict]:
    from .trust import widget_executables
    reviews = []
    for _, path, payload in widget_executables(profile):
        data = canonical_json(payload).encode('utf-8')
        reviews.append({'name': path, 'path': 'widgets.' + path, 'size': len(data),
                        'sha256': _sha(data), 'contents': data.decode('utf-8')})
    return reviews


def export_components(theme: dict, settings: dict, output: Path, preset: str,
                      selected: set[str] | None = None, wallpaper: bool = True,
                      approvals: dict[str, str] | None = None, source_path: Path | None = None,
                      selected_targets: set[str] | None = None,
                      expected_output_digest: str | None = None,
                      package_scripts: bool = True) -> dict:
    chosen = selection(preset, selected, wallpaper)
    components = _source_components(theme, settings, chosen)
    if selected_targets is not None:
        if not selected_targets <= set(settings['targets']):
            raise PortabilityFailure('unknown selected target')
        for name in ('targets', 'target-appearance'):
            if name in components:
                components[name] = {key: value for key, value in components[name].items() if key in selected_targets}
    assets: dict[str, bytes] = {}
    scripts = []
    approvals = approvals or {}
    for item, field, path, kind in _references(components) if package_scripts else []:
        if not _user_script(path):
            continue
        data = _read_script(path)
        digest = _sha(data)
        if path in approvals and approvals[path] != digest:
            raise PortabilityFailure(f'script changed since approval: {path}')
        if path not in approvals:
            _disable(item, field, kind)
            continue
        archive_path = f'assets/scripts/{digest}-{Path(path).name}'
        assets[archive_path] = data
        scripts.append({'name': Path(path).name, 'sourcePath': path, 'path': archive_path,
                        'size': len(data), 'sha256': digest})
        _replace_reference(item, field, path, archive_path, kind)
    if 'wallpaper' in components:
        source = resolve_wallpaper_path(components['wallpaper']['path'], source_path)
        if source.is_symlink() or not source.is_file():
            raise PortabilityFailure(f'wallpaper is not a regular file: {source}')
        data = source.read_bytes()
        if len(data) > MAX_MEMBER_BYTES:
            raise PortabilityFailure('wallpaper exceeds bundle member limit')
        asset_name = f'assets/wallpaper/{_sha(data)}{source.suffix.lower()}'
        assets[asset_name] = data
        components['wallpaper']['path'] = asset_name
    files = {f'components/{name}.json': canonical_json(value).encode() for name, value in components.items()}
    files.update(assets)
    presets = _registry()['bundlePresets']
    matching = [name for name, members in presets.items() if set(chosen) == set(members)]
    actual_preset = preset if preset in matching else matching[0] if matching else 'custom'
    if selected_targets is not None and selected_targets != set(settings['targets']) and 'targets' in chosen:
        actual_preset = 'custom'
    manifest = {'bundleVersion': VERSION, 'componentManifestVersion': _registry()['manifestVersion'],
                'preset': actual_preset,
                'components': list(chosen), 'scripts': scripts,
                'files': {name: {'size': len(data), 'sha256': _sha(data)} for name, data in sorted(files.items())}}
    destination = output.expanduser().absolute()
    if destination.is_symlink() or destination.exists() and (expected_output_digest is None or not destination.is_file() or _sha(destination.read_bytes()) != expected_output_digest):
        raise PortabilityFailure(f'export destination already exists or changed: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix='.blox-bundle-', dir=destination.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, 'w', allowZip64=False) as archive:
            archive.writestr(_zip_info('manifest.json'), canonical_json(manifest).encode())
            for name, data in sorted(files.items()):
                archive.writestr(_zip_info(name), data)
        if temporary.stat().st_size > MAX_BUNDLE_BYTES:
            raise PortabilityFailure('bundle exceeds archive limit')
        if expected_output_digest is None:
            os.link(temporary, destination)
        else:
            if destination.is_symlink() or not destination.is_file() or _sha(destination.read_bytes()) != expected_output_digest:
                raise PortabilityFailure('export destination changed before replacement')
            os.replace(temporary, destination)
        with destination.open('rb') as stream:
            os.fsync(stream.fileno())
        directory_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)
    return manifest


def inspect_components(path: Path) -> tuple[dict, dict, dict]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BUNDLE_BYTES:
        raise PortabilityFailure('unsafe or oversized bundle')
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if len(names) != len(set(names)) or len(names) > 512 or not names or names[0] != 'manifest.json':
                raise PortabilityFailure('invalid bundle members')
            for info in infos:
                member = PurePosixPath(info.filename)
                mode = info.external_attr >> 16
                if (member.is_absolute() or any(part in ('', '.', '..') for part in info.filename.split('/'))
                        or '\\' in info.filename or info.is_dir() or (mode and not stat.S_ISREG(mode))
                        or info.file_size > MAX_MEMBER_BYTES):
                    raise PortabilityFailure(f'unsafe bundle member: {info.filename}')
            if sum(info.file_size for info in infos) > MAX_TOTAL_BYTES:
                raise PortabilityFailure('bundle exceeds extracted size limit')
            with archive.open('manifest.json') as stream:
                manifest = json.loads(stream.read(MAX_MEMBER_BYTES + 1))
            if (type(manifest) is not dict or manifest.get('bundleVersion') != VERSION
                    or manifest.get('componentManifestVersion') != 1 or manifest.get('preset') not in (*_registry()['bundlePresets'], 'custom')
                    or type(manifest.get('components')) is not list or type(manifest.get('files')) is not dict
                    or type(manifest.get('scripts')) is not list):
                raise PortabilityFailure('unsupported component manifest')
            chosen = manifest['components']
            if len(chosen) != len(set(chosen)) or set(manifest['files']) != set(names) - {'manifest.json'}:
                raise PortabilityFailure('bundle manifest differs from members')
            if set(chosen) != {PurePosixPath(name).stem for name in names if name.startswith('components/') and name.endswith('.json')}:
                raise PortabilityFailure('component list differs from members')
            files = {}
            for name, record in manifest['files'].items():
                with archive.open(name) as stream:
                    data = stream.read(MAX_MEMBER_BYTES + 1)
                if len(data) > MAX_MEMBER_BYTES or len(data) != record.get('size') or _sha(data) != record.get('sha256'):
                    raise PortabilityFailure(f'bundle digest mismatch: {name}')
                files[name] = data
            components = {name: json.loads(files[f'components/{name}.json']) for name in chosen}
            for script in manifest['scripts']:
                if (not isinstance(script, dict) or set(script) != {'name', 'sourcePath', 'path', 'size', 'sha256'}
                        or not isinstance(script['path'], str) or not isinstance(script['name'], str)
                        or script['name'] != Path(script['path']).name.split('-', 1)[-1]
                        or script['path'] not in files or not script['path'].startswith('assets/scripts/')
                        or script['size'] != len(files[script['path']]) or script['sha256'] != _sha(files[script['path']])):
                    raise PortabilityFailure('invalid script record')
                files[script['path']].decode('utf-8')
            return manifest, components, files
    except (OSError, zipfile.BadZipFile, json.JSONDecodeError, UnicodeDecodeError, KeyError, TypeError) as error:
        raise PortabilityFailure(f'cannot read component bundle: {error}') from error


def review_import(path: Path) -> list[dict]:
    manifest, components, files = inspect_components(path)
    reviews = [{**script, 'contents': files[script['path']].decode('utf-8')} for script in manifest['scripts']]
    if 'widgets' in components:
        reviews.extend(_widget_reviews(components['widgets']))
    return reviews


def import_components(path: Path, current_theme: dict, current_settings: dict, data_root: Path,
                      selected: set[str] | None = None, approvals: dict[str, str] | None = None,
                      install_assets: bool = True) -> tuple[dict, dict, dict]:
    manifest, components, files = inspect_components(path)
    chosen = set(components) if selected is None else set(selected)
    if not chosen <= set(components):
        raise PortabilityFailure('selected component missing from bundle')
    theme = copy.deepcopy(current_theme)
    settings = copy.deepcopy(current_settings)
    dormant = {}
    supported = {entry['id'] for entry in _registry()['components']} - {'settings-document'}
    for name in chosen:
        value = copy.deepcopy(components[name])
        if name not in supported:
            if manifest['preset'] != 'full':
                raise PortabilityFailure('unknown component outside Full bundle')
            dormant[name] = value
        elif name == 'theme-metadata':
            for key in ('id', 'name', 'variant'):
                theme[key] = value[key]
        elif name == 'appearance':
            for key in APPEARANCE:
                if key in value:
                    theme[key] = value[key]
        elif name == 'wallpaper':
            asset = value['path']
            if asset not in files or not asset.startswith('assets/wallpaper/'):
                raise PortabilityFailure('selected wallpaper asset is missing')
            value['path'] = str(data_root / 'bundle-assets' / Path(asset).name)
            theme['wallpaper'] = value
        elif name == 'targets':
            for target, entry in value.items():
                settings['targets'].setdefault(target, {}).update(entry)
        elif name == 'target-appearance':
            for target, entry in value.items():
                settings['targets'].setdefault(target, {})['overrides'] = entry
        else:
            settings[name] = value
    # A refused file never leaves an active executable reference behind.
    approved = approvals or {}
    installation = {}
    records = {entry['path']: entry for entry in manifest['scripts']}
    if 'widgets' in chosen:
        from .trust import widget_executables
        review_records = {record['path']: record for record in _widget_reviews(settings['widgets'])}
        for item, field_path, _ in widget_executables(settings['widgets']):
            key = 'widgets.' + field_path
            record = review_records[key]
            if key in approved and approved[key] != record['sha256']:
                raise PortabilityFailure(f'widget approval digest differs: {key}')
            if key not in approved:
                item['enabled'] = False
    executable_components = {name: settings[name] for name in chosen & {'widgets', 'binds', 'autostart'}}
    for item, field, head, kind in _references(executable_components):
        if not head.startswith('assets/scripts/'):
            continue
        record = records.get(head)
        if record is None:
            raise PortabilityFailure('unrecorded script reference')
        if head in approved and approved[head] != record['sha256']:
            raise PortabilityFailure(f'script approval digest differs: {head}')
        if head not in approved:
            _disable(item, field, kind)
            continue
        destination = data_root / 'bundle-assets' / Path(head).name
        installation[destination] = files[head]
        _replace_reference(item, field, head, str(destination), kind)
    if 'wallpaper' in chosen:
        installation[Path(theme['wallpaper']['path'])] = files[components['wallpaper']['path']]
    if 'widgets' in chosen:
        # Reopening this imported source must retain the same approval decisions.
        theme['widgets'] = copy.deepcopy(settings['widgets'])
    # Validate the complete result before creating files. Unknown Full data is returned dormant.
    checked = validate_theme(apply_theme_defaults(theme), check_dependencies=False)
    if checked.errors:
        raise PortabilityFailure('invalid imported theme: ' + '; '.join(checked.errors))
    from shell.scripts.settings_document import SettingsDocument
    SettingsDocument()._validate(settings)
    if data_root.name not in ('blox-user', 'blox') or data_root.is_symlink():
        raise PortabilityFailure('assets must be installed below the Blox data root')
    if not install_assets:
        return theme, settings, dormant
    created = []
    try:
        for destination, data in installation.items():
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.parent.is_symlink() or not destination.parent.resolve().is_relative_to(data_root.resolve()):
                raise PortabilityFailure(f'unsafe asset directory: {destination.parent}')
            if destination.exists() or destination.is_symlink():
                if destination.is_symlink() or destination.read_bytes() != data:
                    raise PortabilityFailure(f'asset destination differs: {destination}')
                continue
            fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o700 if destination.suffix not in ('.png', '.jpg', '.jpeg', '.webp') else 0o600)
            created.append(destination)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
    except BaseException:
        for destination in created:
            destination.unlink(missing_ok=True)
        raise
    return theme, settings, dormant
