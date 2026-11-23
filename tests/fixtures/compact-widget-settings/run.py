#!/usr/bin/python
"""Offscreen checks and captures of the production widget editor, with isolated Qt adapters."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def prepare(output, density, radius):
    for name in ('home', 'config', 'state', 'data', 'cache', 'runtime', 'imports/qs/shared', 'images', 'logs'):
        (output / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    shared = output / 'imports/qs/shared'
    baseline = REPO / 'tests/qml/imports/qs/shared'
    lines = []
    for line in (baseline / 'qmldir').read_text().splitlines():
        parts = line.split()
        if parts and parts[-1].endswith('.qml'):
            original = (baseline / parts[-1]).resolve()
            parts[-1] = original.name
            if 'Theme' not in parts and 'PhosphorIcon' not in parts:
                (shared/original.name).write_bytes(original.read_bytes())
            if 'Theme' in parts:
                parts[-1] = 'Theme.qml'
            elif 'PhosphorIcon' in parts:
                parts[-1] = 'PhosphorIcon.qml'
            line = ' '.join(parts)
        lines.append(line)
    (shared / 'qmldir').write_text('\n'.join(lines) + '\n')
    import hashlib
    sources = {path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in shared.glob('*.qml') if path.name not in ('Theme.qml','PhosphorIcon.qml','NativeIcon.qml')}
    (output/'control-hashes.json').write_text(json.dumps(sources,indent=2)+'\n')
    theme = (baseline / 'Theme.qml').read_text()
    theme = theme.replace('return value;', 'return Math.round(value * radiusScale);', 1)
    theme = theme.replace('function scaledSpacing(value) {\n        return value;', 'function scaledSpacing(value) {\n        return Math.round(value * densityScale);')
    colours = {'background':'#242424', 'surface':'#1e1e1e', 'surfaceAlt':'#3b3c4a', 'foreground':'#cdd6f4', 'muted':'#a6adc8', 'border':'#3b3c4a', 'blue':'#89b4fa'}
    import re
    for name, value in colours.items():
        theme = re.sub(r'(property color ' + name + r': )"[^"]+"', r'\1"' + value + '"', theme)
    theme = theme.replace('property real densityScale: 1.0', 'property real densityScale: ' + str(density))
    theme = theme.replace('property real radiusScale: 1.25', 'property real radiusScale: ' + str(radius))
    theme = theme.replace('property string bodyFontFamily: "sans-serif"', 'property string bodyFontFamily: "Google Sans"')
    theme = theme.replace('property string monoFontFamily: "monospace"', 'property string monoFontFamily: "MartianMono Nerd Font Mono"')
    (shared / 'Theme.qml').write_text(theme)
    # The production Controls icon renderer supports offscreen/software tinting.
    native_icon = REPO / 'widgets/qml/Blox/Widgets/Native/NativeIcon.qml'
    if not (shared / 'NativeIcon.qml').exists():
        (shared / 'NativeIcon.qml').symlink_to(native_icon)
    (shared / 'qmldir').write_text((shared / 'qmldir').read_text() + 'NativeIcon 1.0 NativeIcon.qml\n')
    (shared / 'PhosphorIcon.qml').write_text('''import QtQuick
NativeIcon {
    required property string iconName
    property color iconColor: Theme.foreground
    name: iconName
    iconRoot: "file://''' + str(REPO / 'shell/assets/phosphor') + '''/"
    tint: iconColor
}
''')
    io = output/'imports/Quickshell/Io'
    io.mkdir(parents=True,exist_ok=True)
    original_io = REPO/'tests/qml/imports/Quickshell/Io'
    io_lines = []
    for line in (original_io/'qmldir').read_text().splitlines():
        parts = line.split()
        if parts and parts[-1].endswith('.qml'):
            parts[-1] = 'FileView.qml' if 'FileView' in parts else os.path.relpath(original_io/parts[-1], io)
            line = ' '.join(parts)
        io_lines.append(line)
    (io/'qmldir').write_text('\n'.join(io_lines)+'\n')
    # Use Item's existing default data list instead of redeclaring it in the old test stub.
    (io/'FileView.qml').write_text((original_io/'FileView.qml').read_text().replace('    default property alias data: adapterContainer.data\n',''))
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'HYPRLAND_INSTANCE_SIGNATURE', 'QML_IMPORT_PATH', 'QML2_IMPORT_PATH', 'QT_PLUGIN_PATH', 'QT_QPA_PLATFORMTHEME', 'QT_SCALE_FACTOR', 'QT_FONT_DPI', 'QT_SCREEN_SCALE_FACTORS'):
        env.pop(key, None)
    env.update(HOME=str(output / 'home'), XDG_CONFIG_HOME=str(output / 'config'), XDG_STATE_HOME=str(output / 'state'),
               XDG_DATA_HOME=str(output / 'data'), XDG_CACHE_HOME=str(output / 'cache'), XDG_RUNTIME_DIR=str(output / 'runtime'),
               QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
               QSG_RENDER_LOOP='basic', QML_XHR_ALLOW_FILE_READ='1', QML_DISABLE_DISK_CACHE='1',
               DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent-blox-settings-session', DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-blox-settings-system')
    return env


def capture_fixture(args):
    options = dict(kind=args.kind, tab=args.tab, advanced=args.advanced, action=args.action, selected=args.selected,
                   actionKind=args.action_kind, restart=args.restart)
    properties = dict(captureWidth=args.width,captureHeight=args.height,
                      catalogueJson=(REPO/'widgets/catalogue.json').read_text(),schemaJson=(REPO/'widgets/schema/profile.schema.json').read_text())
    source = """import QtQuick
import QtQuick.Window
import QtTest
TestCase {
    id: test
    name: "CompactCapture"
    when: windowShown
    Window {
        id: window
        width: WIDTH
        height: HEIGHT
        visible: true
        Loader { id: loader; anchors.fill: parent }
    }
    function initTestCase() {
        failOnWarning(/.*/);
        loader.setSource(SOURCE, PROPERTIES);
        tryCompare(loader, "status", Loader.Ready);
        wait(100);
        loader.item.configure(OPTIONS);
        window.contentItem.forceActiveFocus();
        wait(100);
        if (FOCUS === "shortcut") loader.item.find("widget-setting-items-add",loader.item).parent.selectedIndex = 0;
        if (FOCUS === "qml" || FOCUS === "qml-nested") {
            const editor = loader.item.find("widget-setting-settings-add",loader.item).parent;
            if (FOCUS === "qml-nested") editor.path = ["palette"];
            editor.select(0);
        }
        function expand(item) {
            if (EXPANDED && item.objectName.endsWith("-expand")) item.clicked();
            if (ADVANCED && item.objectName === ACTIONADVANCED) item.clicked();
            for (const child of item.children) expand(child);
        }
        expand(loader.item);
    }
    function test_capture() {
        wait(200);
        const root = loader.item;
        const scroll = root.find("widget-editor-scroll", root);
        if (BOTTOM) scroll.contentItem.contentY = Math.max(0, scroll.contentHeight - scroll.availableHeight);
        wait(40);
        const items = [];
        function visit(item) {
            if (item.objectName && item.visible) {
                const point = item.mapToItem(root, 0, 0);
                items.push({name:item.objectName,x:point.x,y:point.y,width:item.width,height:item.height});
                if (item.objectName === "widget-editor-scrollbar") items[items.length-1].scroll = {size:item.size,position:item.position};
            }
            for (const child of item.children) visit(child);
        }
        visit(root);
        const image = grabImage(window.contentItem);
        verify(image.width > 0 && image.height > 0);
        image.save(IMAGE);
        console.log("CAPTURE " + JSON.stringify({items:items,draft:root.controller.widgetDraft,error:root.controller.widgetDraftError}));
    }
    function cleanupTestCase() { window.close(); }
}
"""
    replacements = {'WIDTH':str(args.width),'HEIGHT':str(args.height),'SOURCE':json.dumps((HERE/'scene.qml').as_uri()),
                    'PROPERTIES':json.dumps(properties),'OPTIONS':json.dumps(json.dumps(options)),
                    'EXPANDED':str(args.expanded).lower(),'ADVANCED':str(args.advanced).lower(),
                    'ACTIONADVANCED':json.dumps('settings.actions.'+args.action+'-advanced'),
                    'FOCUS':json.dumps(args.focus),
                    'BOTTOM':str(args.bottom).lower(),'IMAGE':json.dumps(str(args.output/'images'/(args.name+'.png')))}
    # Tokens are whole words so replacements cannot alter widget data.
    import re
    source = re.sub(r'\b('+'|'.join(replacements)+r')\b',lambda match:replacements[match[0]],source)
    target = args.output/('tst_capture_'+args.name+'.qml')
    target.write_text(source)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--capture', action='store_true')
    parser.add_argument('--name', default='content')
    parser.add_argument('--kind', default='command')
    parser.add_argument('--tab', type=int, default=0)
    parser.add_argument('--width', type=int, default=800)
    parser.add_argument('--height', type=int, default=640)
    parser.add_argument('--density', type=float, default=0.75)
    parser.add_argument('--radius', type=float, default=0)
    parser.add_argument('--advanced', action='store_true')
    parser.add_argument('--expanded', action='store_true')
    parser.add_argument('--selected', action='store_true')
    parser.add_argument('--bottom', action='store_true')
    parser.add_argument('--action', default='')
    parser.add_argument('--action-kind', choices=('none','run','launch'), default='')
    parser.add_argument('--restart', choices=('never','always'), default='')
    parser.add_argument('--focus', choices=('shortcut','qml','qml-nested'), default='')
    args = parser.parse_args()
    args.output = args.output.resolve()
    env = prepare(args.output, args.density, args.radius)
    source = capture_fixture(args) if args.capture else REPO/'tests/qml/tst_SettingsWidgetCompact.qml'
    command = ['/usr/lib/qt6/bin/qmltestrunner', '-import', str(REPO/'tests/qml/imports'), '-import', str(args.output/'imports'), '-input', str(source)]
    log = args.output/'logs'/(args.name+'.log')
    with log.open('w') as stream:
        try:
            result = subprocess.run(command, env=env, cwd=REPO, stdout=stream, stderr=subprocess.STDOUT, text=True, timeout=45)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    (args.output/'logs'/(args.name+'-command.json')).write_text(json.dumps(dict(command=command,exit=code),indent=2)+'\n')
    contents = log.read_text()
    for line in contents.splitlines():
        if 'qml: CAPTURE ' in line:
            report = json.loads(line.split('qml: CAPTURE ',1)[1])
            report.update(width=args.width,height=args.height,density=args.density,radius=args.radius,backend=env['QT_QUICK_BACKEND'],platform=env['QT_QPA_PLATFORM'])
            (args.output/'logs'/(args.name+'.json')).write_text(json.dumps(report,indent=2)+'\n')
    print('\n'.join(line for line in contents.splitlines() if 'qml: CAPTURE ' not in line))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
