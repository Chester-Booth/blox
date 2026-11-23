#!/usr/bin/env python3
"""One real Settings/theme dataset for both production and reference captures."""
import json
import os
from pathlib import Path
import sys

REPOSITORY = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPOSITORY))
from themes.lib.blox_theme.core import load_theme, canonical_json
from shell.scripts.settings_document import SettingsDocument


def dataset(reference: Path):
    tokens = json.loads((reference / 'fixtures/state/blox/theme/current/quickshell/theme.json').read_text())
    _, theme = load_theme('catppuccin-mocha')
    theme['id'] = 'midnight'; theme['name'] = 'Midnight'
    for key in ('colours', 'fonts', 'shape', 'shell'):
        theme[key] = tokens[key]
    theme.setdefault('overrides', {})['ansi'] = tokens['ansi']
    theme['wallpaper']['path'] = str(reference / 'fixtures/wallpapers/tokyo-night.webp')
    theme['cursor']['sizes'] = [22, 24]
    theme['hyprland']['inactive_opacity'] = 0.92
    theme['hyprland']['border_size'] = 1
    settings = SettingsDocument().defaults
    bar = theme['shell']['bar']
    settings['bar']['layout'] = {'position': bar['position'], 'separateGroups': bar['separate_groups']}
    settings['bar']['style'] = {'border': bar['border'], 'edgeInset': bar['edge_inset'], 'radiusAutomatic': bar['radius_automatic'],
        'radiusScale': bar['radius_scale'], 'densityAutomatic': bar['density_automatic'], 'densityScale': bar['density_scale']}
    settings['widgets']['items'] = [dict(id='clock', name='Clock', type='clock', enabled=False, contentCommand='',
        leftClickCommand='', rightClickCommand='', intervalMs=30000, visibility='always', anchor='centre',
        offsetX=0, offsetY=0, width=0, height=0, shape='auto')]
    style = settings['widgets']['style']
    labels = {'power':'Power', 'notes':'Notes', 'workspaces':'Workspaces', 'clock':'Clock', 'battery':'Battery', 'tray':'Tray',
        'notifications':'Notifications', 'wifi':'Wi-Fi', 'sound':'Sound', 'privacy':'Privacy', 'awake':'Awake',
        'display':'Display', 'bt':'Bluetooth', 'updates':'Updates', 'fan':'Fan', 'gpu':'GPU',
        'application-tray':'Application tray', 'touchpad':'Touchpad', 'active-window-title':'Active window title'}
    mock = {'selectedThemeId':'midnight', 'selectedThemeName':'Midnight', 'barPosition':bar['position'],
        'barSeparateGroups':bar['separate_groups'], 'barBorder':bar['border'], 'barEdgeInset':bar['edge_inset'],
        'barRadius':bar['radius_scale'], 'barDensity':bar['density_scale'], 'radiusScale':theme['shape']['radius_scale'],
        'densityScale':theme['shape']['density_scale'], 'windowGapAutomatic':True, 'inactiveOpacity':0.92, 'borderSize':1,
        'panelFont':theme['fonts']['panel'], 'uiFont':theme['fonts']['ui'], 'monoFont':theme['fonts']['mono'],
        'iconTheme':theme['icons']['theme'], 'widgetStyle':style['preset'], 'widgetOpacity':style['opacity'],
        'widgetPadding':style['padding'], 'widgetRadius':style['radius'], 'widgetFontSize':style['textSize'],
        'barItems':[dict(item, label=labels.get(item['id'],item['id']), kind='button') for item in settings['bar']['items']],
        'widgetItems':[{'id':'clock','label':'Clock','detail':'clock · No content','enabled':False}],
        'semanticColours':[{'label':key.replace('_',' '),'value':value} for key in ('background','surface','surface_alt','foreground','muted','accent','danger','success','warning','info','mauve','teal','selection_background','selection_foreground','border') for value in [theme['colours'][key]]],
        'terminalColours':[tokens['ansi']['color'+str(index)] for index in range(16)]}
    for component in ('osd','notifications'):
        source = theme['shell'][component]
        singular = 'notification' if component == 'notifications' else 'osd'
        mock[singular+'Position'] = source['position']
        mock[singular+'OffsetX'] = source['offset_x']; mock[singular+'OffsetY'] = source['offset_y']
        settings[component] = {'position':source['position'], 'offsetX':source['offset_x'], 'offsetY':source['offset_y']}
    return {'settings':settings, 'theme':theme, 'mock':mock}


if __name__ == '__main__':
    reference = Path(sys.argv[1])
    data = dataset(reference)
    if len(sys.argv) == 3:
        Path(sys.argv[2]).write_text(json.dumps(data, indent=2)+'\n')
    else:
        owner = SettingsDocument()
        result = owner.update_sections({key:value for key,value in data['settings'].items() if key not in ('revision','schemaVersion')}, expected_revision=owner.get().revision)
        if not result.ok:
            raise SystemExit(str(result))
        root = Path(os.environ['BLOX_USER_DATA_DIR']) / 'themes'
        root.mkdir(parents=True)
        (root / 'midnight.json').write_text(canonical_json(data['theme']))
