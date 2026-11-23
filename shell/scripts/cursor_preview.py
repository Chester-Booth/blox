#!/usr/bin/env python3
"""Show the actual cached pointer frame, or recolour its pinned source geometry."""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import struct
import sys
import zlib

PRODUCT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PRODUCT_ROOT))
from themes.lib.blox_theme.core import state_dir
from themes.lib.blox_theme.cursor import cursor_metadata, validate_cursor_cache


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def xcursor_frame(path: Path, requested: int) -> dict:
    """Decode one nearest-size Xcursor frame without changing the installed cursor."""
    if path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError('cursor file exceeds preview limit')
    data = path.read_bytes()
    magic, header, version, count = struct.unpack_from('<4sIII', data)
    if magic != b'Xcur' or header < 16 or count > 4096 or header + count * 12 > len(data):
        raise ValueError('invalid Xcursor header')
    frames = []
    for index in range(count):
        kind, size, offset = struct.unpack_from('<III', data, header + index * 12)
        if kind == 0xFFFD0002:
            frames.append((abs(size - requested), offset))
    if not frames:
        raise ValueError('cursor has no image frame')
    offset = min(frames, key=lambda frame: frame[0])[1]
    chunk_header, kind, nominal, version, width, height, hot_x, hot_y, delay = struct.unpack_from('<9I', data, offset)
    if chunk_header < 36 or not 0 < width <= 512 or not 0 < height <= 512 or hot_x >= width or hot_y >= height:
        raise ValueError('invalid cursor image frame')
    pixels = data[offset + chunk_header:offset + chunk_header + width * height * 4]
    if len(pixels) != width * height * 4:
        raise ValueError('truncated cursor image')
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            blue, green, red, alpha = pixels[(y * width + x) * 4:(y * width + x + 1) * 4]
            rows.extend((min(255, round(red * 255 / alpha)) if alpha else 0,
                         min(255, round(green * 255 / alpha)) if alpha else 0,
                         min(255, round(blue * 255 / alpha)) if alpha else 0, alpha))
    png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>2I5B', width, height, 8, 6, 0, 0, 0))
    png += png_chunk(b'IDAT', zlib.compress(bytes(rows))) + png_chunk(b'IEND', b'')
    return {'source': 'data:image/png;base64,' + base64.b64encode(png).decode(),
            'width': width, 'height': height, 'hotspotX': hot_x, 'hotspotY': hot_y, 'kind': 'native-frame'}


def preview(theme: dict) -> dict:
    metadata = cursor_metadata(theme)
    size = metadata['size']
    if type(size) is not int or not 1 <= size <= 128:
        raise ValueError('invalid cursor size')
    if metadata['mode'] == 'installed':
        name = metadata['theme_name']
        if not isinstance(name, str) or not name or '/' in name or name in {'.', '..'}:
            raise ValueError('invalid installed cursor name')
        data_home = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
        roots = [data_home / 'icons', Path.home() / '.icons']
        roots.extend(Path(value) / 'icons' for value in os.environ.get('XDG_DATA_DIRS', '/usr/local/share:/usr/share').split(':') if value)
        for root in roots:
            path = root / name / 'cursors/left_ptr'
            if path.is_file():
                return xcursor_frame(path, size)
        raise ValueError('installed cursor pointer is unavailable')
    cache = state_dir() / 'cursors' / metadata['cache_key']
    if validate_cursor_cache(cache, metadata):
        return xcursor_frame(cache / 'theme/cursors/left_ptr', size)
    shape = 'original' if metadata['style'] == 'Bibata-Original-Classic' else 'modern'
    direction = metadata['handedness']
    if direction not in {'left', 'right'}:
        raise ValueError('invalid cursor direction')
    assets = PRODUCT_ROOT / 'shell/assets/bibata-preview'
    variant = f'{shape}-{direction}'
    record = json.loads((assets / 'source.json').read_text())['frames'][variant]
    svg = (assets / f'{variant}.svg').read_text()
    colours = metadata['colours']
    for marker, key in [('#00FF00', 'base'), ('#0000FF', 'outline'), ('#FF0000', 'watch_background')]:
        value = colours[key]
        if not isinstance(value, str) or not re.fullmatch(r'#[0-9a-fA-F]{6}', value):
            raise ValueError('invalid cursor colour')
        svg = svg.replace(marker, value)
    svg = svg.replace('width="256" height="256"', f'width="{size}" height="{size}"')
    return {'source': 'data:image/svg+xml;base64,' + base64.b64encode(svg.encode()).decode(),
            'width': size, 'height': size, 'hotspotX': int(record['hotspotX'] * size / 256),
            'hotspotY': int(record['hotspotY'] * size / 256), 'kind': 'source-geometry'}


def main() -> int:
    try:
        if len(sys.argv) != 2 or len(sys.argv[1]) > 1024 * 1024:
            raise ValueError('invalid preview request')
        result = preview(json.loads(sys.argv[1]))
        print(json.dumps({'ok': True, 'data': result}))
        return 0
    except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
        print(json.dumps({'ok': False, 'message': str(error)}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
