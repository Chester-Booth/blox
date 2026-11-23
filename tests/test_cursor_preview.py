"""Pointer previews use native cursor pixels and the pinned generated geometry."""
import base64
import copy
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

from shell.scripts.cursor_preview import preview, xcursor_frame
from themes.lib.blox_theme.core import load_theme

REPO_THEMES = Path(__file__).resolve().parents[1] / "themes"


class CursorPreviewTests(unittest.TestCase):
    def setUp(self):
        with patch.dict(os.environ, {"BLOX_DATA_DIR": os.environ.get("BLOX_DATA_DIR") or str(REPO_THEMES)}):
            self.theme = copy.deepcopy(load_theme("catppuccin-frappe")[1])
        self.theme["cursor"]["handedness"] = "right"

    def test_generated_preview_tracks_direction_shape_size_and_colour(self):
        with patch('shell.scripts.cursor_preview.validate_cursor_cache', return_value=False):
            right = preview(self.theme)
            self.theme['cursor']['handedness'] = 'left'
            self.theme['cursor']['sizes'] = [48]
            self.theme['shape']['radius_scale'] = 0
            self.theme['cursor']['base_colour'] = '#123456'
            left = preview(self.theme)
        self.assertEqual(right['kind'], 'source-geometry')
        self.assertEqual((left['width'], left['height']), (48, 48))
        self.assertLess(left['hotspotX'], right['hotspotX'])
        svg = base64.b64decode(left['source'].split(',', 1)[1]).decode()
        self.assertIn('#123456', svg)
        self.assertNotEqual(left['source'], right['source'])

    def test_native_frame_preserves_hotspot_and_unpremultiplies_pixels(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'left_ptr'
            header = struct.pack('<4sIII', b'Xcur', 16, 0x10000, 1)
            toc = struct.pack('<III', 0xFFFD0002, 24, 28)
            image = struct.pack('<9I', 36, 0xFFFD0002, 24, 1, 2, 1, 1, 0, 0)
            path.write_bytes(header + toc + image + bytes([0, 0, 128, 128, 0, 255, 0, 255]))
            result = xcursor_frame(path, 26)
        self.assertEqual((result['width'], result['height'], result['hotspotX']), (2, 1, 1))
        png = base64.b64decode(result['source'].split(',', 1)[1])
        offset = 8
        while offset < len(png):
            length = struct.unpack_from('>I', png, offset)[0]
            if png[offset + 4:offset + 8] == b'IDAT':
                self.assertEqual(zlib.decompress(png[offset + 8:offset + 8 + length]), bytes([0, 255, 0, 0, 128, 0, 255, 0, 255]))
                break
            offset += length + 12
        else:
            self.fail('PNG has no image pixels')

    def test_truncated_native_cursor_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'left_ptr'
            path.write_bytes(struct.pack('<4sIII', b'Xcur', 16, 0x10000, 4096))
            with self.assertRaises(ValueError):
                xcursor_frame(path, 26)


if __name__ == '__main__':
    unittest.main()
