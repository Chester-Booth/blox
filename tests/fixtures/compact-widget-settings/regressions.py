#!/usr/bin/python
"""Compare production QV4 validation with Python and exercise the real offscreen editor."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('compact_runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
sys.path.insert(0, str(REPO / 'widgets/lib'))
from blox_widgets.model import default_widget, validate_profile, ValidationError, _validate


def cases():
    schema = json.loads((REPO / 'widgets/schema/profile.schema.json').read_text())
    catalogue = json.loads((REPO / 'widgets/catalogue.json').read_text())
    bases = {}
    for entry in catalogue['widgets']:
        kind = entry['kind']
        settings = copy.deepcopy(entry['defaultSettings'])
        if kind in ('command', 'terminal'):
            settings['command'] = ['example', 'argument']
            settings['environment'] = {'EXAMPLE': 'value'}
            settings['workingDirectory'] = '/tmp'
        if kind == 'weather':
            settings.update(latitude=51.5, longitude=-0.1)
        if kind == 'qml':
            settings.update(manifest='example', providers=['clock'], layouts=['native', 'fit'], settings={'key': 'text'})
        if kind == 'shortcuts':
            settings['items'] = [{'id': 'example', 'label': 'Example', 'command': ['example', 'arg']}]
        if kind == 'network':
            settings['interfaces'] = ['eth0']
        if kind == 'command':
            settings['actions'] = {
                'left': {'kind': 'run', 'command': ['action', 'arg'], 'workingDirectory': '/tmp', 'environment': {'EXAMPLE': 'value'}, 'timeoutSeconds': 15},
                'right': {'kind': 'launch', 'command': ['action', 'arg']}}
        widget = default_widget(kind, kind, settings)
        widget['workspaces'] = {'mode': 'include', 'ids': ['desk'], 'ranges': []}
        bases[kind] = widget
    result = []

    def add(name, kind, path=(), value=None, format_case=False):
        widget = copy.deepcopy(bases[kind])
        if path:
            parent = widget
            for key in path[:-1]:
                parent = parent[key]
            parent[path[-1]] = value
        try:
            validate_profile({'schemaVersion': 1, 'widgets': [widget]})
            valid, error = True, ''
        except ValidationError as exc:
            valid, error = False, str(exc)
        result.append(dict(name=name, widget=widget, backendValid=valid, backendError=error, formatCase=format_case))

    def visit(kind, value, rule, path=()):
        if '$ref' in rule:
            target = schema
            for key in rule['$ref'][2:].split('/'):
                target = target[key]
            rule = target
        for union in ('oneOf', 'anyOf'):
            if union in rule:
                for branch in rule[union]:
                    try:
                        _validate(value, branch, schema, 'value')
                    except ValidationError:
                        continue
                    visit(kind, value, branch, path)
                    break
                return
        if isinstance(value, str):
            if rule.get('format') == 'blox-timezone':
                return
            for bound in ('minLength', 'maxLength'):
                if bound not in rule:
                    continue
                limit = rule[bound]
                for size in sorted({max(0, limit - 1), limit, limit + 1}):
                    for label, text in [('ascii', 'a' * size), ('supplementary', '😀' * size), ('mixed', 'a' + '😀' * max(0, size - 1) if size else '')]:
                        # Keep the absolute-path prefix for workingDirectory boundaries.
                        if path[-1] == 'workingDirectory' and text:
                            text = '/' + text[1:] if label == 'ascii' else '/' + ('😀' * max(0, size - 1))
                        add(kind + '.' + '.'.join(map(str, path)) + f'-{bound}-{size}-{label}', kind, path, text)
            if 'x-blox-maxUtf8Bytes' in rule:
                for index, text in enumerate(['\ud800', '\udfff', '\ud800x', '\ud800\ud800', 'x\udfff', '😀\ud800']):
                    add(kind + '.' + '.'.join(map(str, path)) + f'-invalid-surrogate-{index}', kind, path, text)
        elif isinstance(value, dict):
            for key, child in value.items():
                if 'propertyNames' in rule and 'maxLength' in rule['propertyNames']:
                    limit = rule['propertyNames']['maxLength']
                    for size in (0, 65, limit - 1, limit, limit + 1):
                        replacement = {**value}
                        del replacement[key]
                        replacement['😀' * size] = child
                        add(kind + '.' + '.'.join(map(str, path)) + f'-key-{size}', kind, path, replacement)
                child_rule = rule.get('properties', {}).get(key, rule.get('additionalProperties'))
                if isinstance(child_rule, dict):
                    visit(kind, child, child_rule, (*path, key))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                child_rule = rule.get('prefixItems', [])[index] if index < len(rule.get('prefixItems', [])) else rule.get('items')
                if isinstance(child_rule, dict):
                    visit(kind, child, child_rule, (*path, index))

    for kind, widget in bases.items():
        add('default-' + kind, kind)
        rule = next(rule for rule in schema['properties']['widgets']['items']['oneOf'] if rule['properties']['kind']['const'] == kind)
        visit(kind, widget, rule)
    for size in (64, 65, 128, 129):
        add(f'workspace-exact-{size}', 'clock', ('workspaces', 'ids'), ['😀' * size])
    for size in (2048, 2049, 3000, 4096, 4097):
        add(f'argv-exact-{size}', 'command', ('settings', 'command'), ['x', '😀' * size])
    for key in ('__proto__', 'constructor', 'prototype'):
        add('qml-special-' + key, 'qml', ('settings', 'settings'), {key: {key: [True, None, {'safe': True}]}, 'sibling': 12})
    for label, path, value in [
        ('empty-command', ('settings', 'command'), []),
        ('empty-executable', ('settings', 'command'), ['']),
        ('nul-arg', ('settings', 'command'), ['x', '\0']),
        ('numeric-arg', ('settings', 'command'), ['x', 1]),
        ('bad-env-name', ('settings', 'environment'), {'A-B': 'x'}),
        ('nontext-env', ('settings', 'environment'), {'A': 1}),
        ('reserved-env', ('settings', 'environment'), {'BLOX_WIDGET_ACTION_CONTEXT': 'x'}),
        ('relative-cwd', ('settings', 'workingDirectory'), 'relative'),
        ('interval-low', ('settings', 'intervalSeconds'), 0.249),
        ('timeout-high', ('settings', 'timeoutSeconds'), 86401),
        ('missing-right', ('settings', 'actions'), {'left': None}),
        ('launch-extra', ('settings', 'actions'), {'left': {'kind': 'launch', 'command': ['x'], 'environment': {}}, 'right': None}),
        ('run-timeout', ('settings', 'actions'), {'left': {'kind': 'run', 'command': ['x'], 'workingDirectory': '', 'environment': {}, 'timeoutSeconds': 120.001}, 'right': None}),
        ('typed-workspaces', ('workspaces', 'ids'), [2, '2']),
        ('duplicate-ids', ('workspaces', 'ids'), [2, 2]),
        ('workspace-large', ('workspaces', 'ids'), [1000001]),
        ('descending-range', ('workspaces', 'ranges'), [[4, 2]]),
        ('duplicate-ranges', ('workspaces', 'ranges'), [[1, 2], [1, 2]]),
    ]:
        add(label, 'command', path, value)
    for rows in (50, 51):
        settings = copy.deepcopy(bases['terminal']['settings'])
        settings.update(columns=240, rows=rows)
        add(f'terminal-cells-{rows}', 'terminal', ('settings',), settings)
    add('terminal-invalid-restart', 'terminal', ('settings', 'restartPolicy'), 'sometimes')
    add('qml-large-number', 'qml', ('settings', 'settings'), {'number': 1e13})
    add('duplicate-shortcut', 'shortcuts', ('settings', 'items'), [{'id': 'same', 'label': 'A', 'command': ['x']}, {'id': 'same', 'label': 'B', 'command': ['y']}])
    for label, path, value in [('missing-command', ('settings',), {k: v for k, v in bases['command']['settings'].items() if k != 'command'}), ('unknown-field', ('settings',), {**bases['command']['settings'], 'extra': True})]:
        add(label, 'command', path, value)
    add('timezone-authoritative', 'clock', ('settings', 'timezone'), 'Definitely/NotAZone', True)
    return result


def snapshot(output, preimages):
    """Freeze the modules so old and new runs cannot accidentally mix source versions."""
    target = output / 'source/shell/modules'
    shutil.copytree(REPO / 'shell/modules', target, dirs_exist_ok=True)
    shared = target.parent / 'shared'
    if not shared.exists():
        shared.symlink_to(REPO / 'shell/shared', target_is_directory=True)
    assets = target.parent / 'assets'
    if not assets.exists():
        assets.symlink_to(REPO / 'shell/assets', target_is_directory=True)
    if preimages:
        for name in ('SettingsWidgetJsonEditor.qml', 'SettingsWidgetController.qml', 'SettingsWidgetEditor.qml'):
            shutil.copyfile(preimages / 'shell/modules' / name, target / name)
    imports = output / 'imports/qs/modules'
    imports.mkdir(parents=True, exist_ok=True)
    baseline = REPO / 'tests/qml/imports/qs/modules'
    lines = []
    for line in (baseline / 'qmldir').read_text().splitlines():
        parts = line.split()
        if parts and parts[-1].endswith('.qml'):
            original = (baseline / parts[-1]).resolve()
            parts[-1] = os.path.relpath(target / original.name if original.parent == REPO / 'shell/modules' else original, imports)
            line = ' '.join(parts)
        lines.append(line)
    (imports / 'qmldir').write_text('\n'.join(lines) + '\n')
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in target.glob('*.qml')}
    (output / 'module-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--preimages', type=Path, help='Optional captured three-file preimage tree for old-fail proof.')
    parser.add_argument('tests', nargs='*', help='Optional QtTest functions.')
    args = parser.parse_args()
    output = args.output.resolve()
    env = runner.prepare(output, 1, 0)
    snapshot(output, args.preimages)
    samples = cases()
    (output / 'validation-cases.json').write_text(json.dumps(samples, ensure_ascii=True) + '\n')
    source = (REPO / 'tests/qml/tst_SettingsWidgetDataSafety.qml').read_text()
    source = source.replace('../../widgets/', (REPO / 'widgets').as_uri() + '/')
    test = output / 'tst_SettingsWidgetDataSafety.qml'
    test.write_text(source)
    command = ['/usr/lib/qt6/bin/qmltestrunner', '-import', str(REPO / 'tests/qml/imports'), '-import', str(output / 'imports'), '-input', str(test), *args.tests]
    process = subprocess.run(command, env=env, cwd=REPO, text=True, capture_output=True, timeout=180)
    log = process.stdout + process.stderr
    (output / 'logs/result.log').write_text(log)
    (output / 'command.json').write_text(json.dumps(dict(command=command, exit=process.returncode, cases=len(samples)), indent=2) + '\n')
    for line in log.splitlines():
        if 'qml: DIFFERENTIAL ' in line:
            (output / 'differential-results.json').write_text(json.dumps(json.loads(line.split('qml: DIFFERENTIAL ', 1)[1]), indent=2) + '\n')
        else:
            print(line)
    return process.returncode or (1 if 'QWARN' in log else 0)


if __name__ == '__main__':
    sys.exit(main())
