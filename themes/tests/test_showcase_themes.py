from __future__ import annotations

import hashlib
import json
import sys
import unittest
from collections import defaultdict
from pathlib import Path


THEMES = Path(__file__).resolve().parents[1]
REPOSITORY = THEMES.parent
SHOWCASE_WALLPAPERS = THEMES / "wallpapers/showcase"
SHOWCASE_IDS = (
    "catppuccin-latte",
    "catppuccin-frappe",
    "catppuccin-macchiato",
    "catppuccin-mocha",
    "gruvbox-dark",
    "gruvbox-light",
    "nord",
    "solarized-dark",
    "solarized-light",
    "tokyo-night",
    "dracula",
    "kanagawa",
)
ANSI_KEYS = frozenset(f"color{index}" for index in range(16))
HEX_COLOUR_LENGTH = 7
MAX_WALLPAPER_BYTES = 16 * 1024 * 1024
MIN_WALLPAPER_WIDTH = 1280
MIN_WALLPAPER_HEIGHT = 720

# These are unchanged values from the projects named in the implementation
# plan. Keep them local to this test: a palette change must be deliberate and
# reviewed alongside its upstream authority.
OFFICIAL_PALETTES = {
    "catppuccin-latte": frozenset("dc8a78 dd7878 ea76cb 8839ef d20f39 e64553 fe640b df8e1d 40a02b 179299 04a5e5 209fb5 1e66f5 7287fd 4c4f69 5c5f77 6c6f85 7c7f93 8c8fa1 9ca0b0 acb0be bcc0cc ccd0da eff1f5 e6e9ef dce0e8".split()),
    "catppuccin-frappe": frozenset("f2d5cf eebebe f4b8e4 ca9ee6 e78284 ea999c ef9f76 e5c890 a6d189 81c8be 99d1db 85c1dc 8caaee babbf1 c6d0f5 b5bfe2 a5adce 949cbb 838ba7 737994 626880 51576d 414559 303446 292c3c 232634".split()),
    "catppuccin-macchiato": frozenset("f4dbd6 f0c6c6 f5bde6 c6a0f6 ed8796 ee99a0 f5a97f eed49f a6da95 8bd5ca 91d7e3 7dc4e4 8aadf4 b7bdf8 cad3f5 b8c0e0 a5adcb 939ab7 8087a2 6e738d 5b6078 494d64 363a4f 24273a 1e2030 181926".split()),
    "catppuccin-mocha": frozenset("f5e0dc f2cdcd f5c2e7 cba6f7 f38ba8 eba0ac fab387 f9e2af a6e3a1 94e2d5 89dceb 74c7ec 89b4fa b4befe cdd6f4 bac2de a6adc8 9399b2 7f849c 6c7086 585b70 45475a 313244 1e1e2e 181825 11111b".split()),
    "gruvbox-dark": frozenset("282828 3c3836 504945 665c54 7c6f64 928374 a89984 bdae93 ebdbb2 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c fe8019 cc241d 98971a d79921 458588 b16286 689d6a d65d0e 9d0006 79740e b57614 076678 8f3f71 427b58 af3a03".split()),
    "gruvbox-light": frozenset("fbf1c7 ebdbb2 d5c4a1 bdae93 a89984 928374 665c54 504945 3c3836 282828 9d0006 79740e b57614 076678 8f3f71 427b58 af3a03 cc241d 98971a d79921 458588 b16286 689d6a d65d0e".split()),
    "nord": frozenset("2e3440 3b4252 434c5e 4c566a d8dee9 e5e9f0 eceff4 8fbcbb 88c0d0 81a1c1 5e81ac bf616a d08770 ebcb8b a3be8c b48ead".split()),
    "solarized-dark": frozenset("002b36 073642 586e75 657b83 839496 93a1a1 eee8d5 fdf6e3 b58900 cb4b16 dc322f d33682 6c71c4 268bd2 2aa198 859900".split()),
    "solarized-light": frozenset("002b36 073642 586e75 657b83 839496 93a1a1 eee8d5 fdf6e3 b58900 cb4b16 dc322f d33682 6c71c4 268bd2 2aa198 859900".split()),
    "tokyo-night": frozenset("1a1b26 16161e 0f0f14 1f2335 283457 292e42 3b4261 414868 545c7e 565f89 737aa2 a9b1d6 c0caf5 7aa2f7 3d59a1 2ac3de 0db9d7 89ddff b4f9f8 394b70 7dcfff 9ece6a 73daca 41a6b5 bb9af7 9d7cd8 ff007c ff9e64 f7768e db4b4b 1abc9c e0af68".split()),
    "dracula": frozenset("282a36 44475a 6272a4 f8f8f2 8be9fd 50fa7b f1fa8c ffb86c ff79c6 bd93f9 ff5555 21222c 191a21 ff6e6e 69ff94 ffffa5 d6acff ff92df a4ffff ffffff".split()),
    "kanagawa": frozenset("16161d 1f1f28 2a2a37 363646 54546d 223249 2d4f67 2b3328 49443c 43242b 252535 76946a c34043 dca561 e82424 ff9e3b 6a9589 658594 dcd7ba c8c093 957fb8 b8b4d0 7e9cd8 938aa9 9cabca 7fb4ca a3d4d5 7aa89f 98bb6c 938056 c0a36e e6c384 d27e99 e46876 ff5d62 ffa066 717c7c 727169".split()),
}

sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import load_theme, validate_theme


def webp_dimensions(path: Path) -> tuple[int, int]:
    """Read WebP dimensions without adding a test-only image dependency."""
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("not a RIFF WebP file")
    offset = 12
    while offset + 8 <= len(data):
        kind = data[offset:offset + 4]
        length = int.from_bytes(data[offset + 4:offset + 8], "little")
        payload = data[offset + 8:offset + 8 + length]
        if len(payload) != length:
            raise ValueError("truncated WebP chunk")
        if kind == b"VP8X" and length >= 10:
            return (
                int.from_bytes(payload[4:7], "little") + 1,
                int.from_bytes(payload[7:10], "little") + 1,
            )
        if kind == b"VP8 " and length >= 10 and payload[3:6] == b"\x9d\x01\x2a":
            return (
                int.from_bytes(payload[6:8], "little") & 0x3FFF,
                int.from_bytes(payload[8:10], "little") & 0x3FFF,
            )
        if kind == b"VP8L" and length >= 5 and payload[0] == 0x2F:
            bits = int.from_bytes(payload[1:5], "little")
            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        offset += 8 + length + (length % 2)
    raise ValueError("WebP image has no supported dimensions chunk")


def webp_xmp(path: Path) -> str:
    data = path.read_bytes()
    offset = 12
    while offset + 8 <= len(data):
        kind = data[offset:offset + 4]
        length = int.from_bytes(data[offset + 4:offset + 8], "little")
        payload = data[offset + 8:offset + 8 + length]
        if kind == b"XMP ":
            return payload.decode("utf-8")
        offset += 8 + length + (length % 2)
    raise ValueError("WebP image has no XMP metadata")


def hex_colours(value: object) -> set[str]:
    if isinstance(value, dict):
        return set().union(*(hex_colours(item) for item in value.values()))
    if isinstance(value, list):
        return set().union(*(hex_colours(item) for item in value))
    if isinstance(value, str) and len(value) == HEX_COLOUR_LENGTH and value.startswith("#"):
        return {value[1:].lower()}
    return set()


class ShowcaseThemeTests(unittest.TestCase):
    def showcase_themes(self) -> dict[str, dict]:
        source_ids = {path.stem for path in (THEMES / "builtin").glob("*.json")}
        missing = sorted(set(SHOWCASE_IDS) - source_ids)
        self.assertEqual([], missing, f"missing showcase theme sources: {', '.join(missing)}")
        return {theme_id: load_theme(theme_id)[1] for theme_id in SHOWCASE_IDS}

    def test_showcase_ids_exist_and_validate(self) -> None:
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                self.assertEqual(theme_id, theme["id"])
                self.assertEqual([], validate_theme(theme, check_dependencies=False).errors)

    def test_showcase_wallpapers_are_repository_relative_webp_assets(self) -> None:
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                self.assertTrue(theme["targets"]["wallpaper"])
                relative = Path(theme["wallpaper"]["path"])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                self.assertEqual(".webp", relative.suffix.lower())
                self.assertEqual(Path("wallpapers/showcase"), relative.parent)
                self.assertEqual(f"{theme_id}.webp", relative.name)
                self.assertTrue((THEMES / relative).is_file())

    def test_font_sets_and_bar_compositions_are_distinct(self) -> None:
        font_sets = set()
        compositions = set()
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                font_set = tuple(theme["fonts"][role] for role in ("ui", "mono", "panel"))
                self.assertNotIn(font_set, font_sets, f"{theme_id} repeats a showcase font set")
                font_sets.add(font_set)

                bar = theme["shell"]["bar"]
                items = bar.get("items", [])
                self.assertTrue(items, "showcase bars must state their intended composition")
                self.assertEqual(len(items), len({item["id"] for item in items}))
                orders: dict[str, set[int]] = defaultdict(set)
                for item in items:
                    self.assertNotIn(item["order"], orders[item["region"]])
                    orders[item["region"]].add(item["order"])
                composition = json.dumps(bar, sort_keys=True, separators=(",", ":"))
                self.assertNotIn(composition, compositions, f"{theme_id} repeats a showcase bar composition")
                compositions.add(composition)

    def test_showcase_sources_pin_both_trays_towards_empty_space(self) -> None:
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                items = theme["shell"]["bar"]["items"]
                tray = next(item for item in items if item["id"] == "tray")
                application = next(item for item in items if item["id"] == "application-tray")
                visible = sorted(
                    (item for item in items if item["region"] == tray["region"]),
                    key=lambda item: item["order"],
                )
                self.assertNotEqual("hidden", tray["region"])
                if tray["region"] == "start":
                    self.assertEqual("tray", visible[-1]["id"])
                elif tray["region"] == "end":
                    self.assertEqual("tray", visible[0]["id"])
                else:
                    self.assertIn("tray", (visible[0]["id"], visible[-1]["id"]))

                hidden = sorted(
                    (item for item in items if item["region"] == "hidden"),
                    key=lambda item: item["order"],
                )
                opens_forward = tray["region"] == "start" or tray["region"] == "centre" and visible[-1]["id"] == "tray"
                expected = hidden[-1] if opens_forward else hidden[0]
                self.assertEqual("hidden", application["region"])
                self.assertEqual("application-tray", expected["id"])

    def test_only_the_three_widget_showcases_bundle_widgets(self) -> None:
        expected = {
            "dracula": "pipes",
            "kanagawa": "aquarium",
            "tokyo-night": "music",
        }
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                items = theme.get("widgets", {}).get("items", [])
                if theme_id in expected:
                    self.assertEqual([expected[theme_id]], [item["type"] for item in items])
                else:
                    self.assertEqual([], items)

    def test_all_colours_are_unmodified_official_swatches_with_complete_ansi(self) -> None:
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                self.assertEqual("override", theme["terminal"]["ansi_source"])
                ansi = theme.get("overrides", {}).get("ansi", {})
                self.assertEqual(ANSI_KEYS, frozenset(ansi))
                values = hex_colours(theme)
                unknown = sorted(values - OFFICIAL_PALETTES[theme_id])
                self.assertEqual([], unknown, f"non-official or blended colour values: {unknown}")

    def test_wallpaper_assets_have_desktop_safe_dimensions_and_source_ledger(self) -> None:
        ledger_path = SHOWCASE_WALLPAPERS / "SOURCES.md"
        self.assertTrue(ledger_path.is_file(), "consolidate temporary source notes into SOURCES.md")
        ledger = ledger_path.read_text(encoding="utf-8").casefold()
        for field in ("http", "commit", "author", "licen", "sha-256", "process"):
            self.assertIn(field, ledger, f"source ledger must record {field}")
        for theme_id, theme in self.showcase_themes().items():
            with self.subTest(theme=theme_id):
                relative = Path(theme["wallpaper"]["path"])
                asset = THEMES / relative
                self.assertIn(relative.name.casefold(), ledger)
                self.assertIn(hashlib.sha256(asset.read_bytes()).hexdigest(), ledger)
                self.assertLessEqual(asset.stat().st_size, MAX_WALLPAPER_BYTES)
                width, height = webp_dimensions(asset)
                self.assertGreaterEqual(width, MIN_WALLPAPER_WIDTH)
                self.assertGreaterEqual(height, MIN_WALLPAPER_HEIGHT)
                metadata = webp_xmp(asset)
                for marker in ("<dc:creator>", "<dc:source>", "<dc:rights>", "<xmpRights:UsageTerms>", "<cc:license"):
                    self.assertIn(marker, metadata)
                self.assertIn("Source SHA-256:", metadata)
                self.assertIn("Processing:", metadata)


if __name__ == "__main__":
    unittest.main()
