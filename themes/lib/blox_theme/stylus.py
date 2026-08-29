from __future__ import annotations

import copy
import re
from pathlib import Path
from typing import Any

from .core import canonical_json, load_json, themes_dir


CATPPUCCIN_REVISION = "5ef4cc64231826f46d12a2721fa72571f5aa8a27"
SOURCE_URL = "https://github.com/catppuccin/userstyles"
SOURCE_ROOT_NAME = "sources/catppuccin"
STYLE_SET_VALUES = ("recommended", "unmaintained", "all")

CATPPUCCIN_MOCHA = {
    "rosewater": "#f5e0dc",
    "flamingo": "#f2cdcd",
    "pink": "#f5c2e7",
    "mauve": "#cba6f7",
    "red": "#f38ba8",
    "maroon": "#eba0ac",
    "peach": "#fab387",
    "yellow": "#f9e2af",
    "green": "#a6e3a1",
    "teal": "#94e2d5",
    "sky": "#89dceb",
    "sapphire": "#74c7ec",
    "blue": "#89b4fa",
    "lavender": "#b4befe",
    "text": "#cdd6f4",
    "subtext1": "#bac2de",
    "subtext0": "#a6adc8",
    "overlay2": "#9399b2",
    "overlay1": "#7f849c",
    "overlay0": "#6c7086",
    "surface2": "#585b70",
    "surface1": "#45475a",
    "surface0": "#313244",
    "base": "#1e1e2e",
    "mantle": "#181825",
    "crust": "#11111b",
}

CATPPUCCIN_PALETTES = {
    "latte": {
        "rosewater": "#dc8a78",
        "flamingo": "#dd7878",
        "pink": "#ea76cb",
        "mauve": "#8839ef",
        "red": "#d20f39",
        "maroon": "#e64553",
        "peach": "#fe640b",
        "yellow": "#df8e1d",
        "green": "#40a02b",
        "teal": "#179299",
        "sky": "#04a5e5",
        "sapphire": "#209fb5",
        "blue": "#1e66f5",
        "lavender": "#7287fd",
        "text": "#4c4f69",
        "subtext1": "#5c5f77",
        "subtext0": "#6c6f85",
        "overlay2": "#7c7f93",
        "overlay1": "#8c8fa1",
        "overlay0": "#9ca0b0",
        "surface2": "#acb0be",
        "surface1": "#bcc0cc",
        "surface0": "#ccd0da",
        "base": "#eff1f5",
        "mantle": "#e6e9ef",
        "crust": "#dce0e8",
    },
    "frappe": {
        "rosewater": "#f2d5cf",
        "flamingo": "#eebebe",
        "pink": "#f4b8e4",
        "mauve": "#ca9ee6",
        "red": "#e78284",
        "maroon": "#ea999c",
        "peach": "#ef9f76",
        "yellow": "#e5c890",
        "green": "#a6d189",
        "teal": "#81c8be",
        "sky": "#99d1db",
        "sapphire": "#85c1dc",
        "blue": "#8caaee",
        "lavender": "#babbf1",
        "text": "#c6d0f5",
        "subtext1": "#b5bfe2",
        "subtext0": "#a5adce",
        "overlay2": "#949cbb",
        "overlay1": "#838ba7",
        "overlay0": "#737994",
        "surface2": "#626880",
        "surface1": "#51576d",
        "surface0": "#414559",
        "base": "#303446",
        "mantle": "#292c3c",
        "crust": "#232634",
    },
    "macchiato": {
        "rosewater": "#f4dbd6",
        "flamingo": "#f0c6c6",
        "pink": "#f5bde6",
        "mauve": "#c6a0f6",
        "red": "#ed8796",
        "maroon": "#ee99a0",
        "peach": "#f5a97f",
        "yellow": "#eed49f",
        "green": "#a6da95",
        "teal": "#8bd5ca",
        "sky": "#91d7e3",
        "sapphire": "#7dc4e4",
        "blue": "#8aadf4",
        "lavender": "#b7bdf8",
        "text": "#cad3f5",
        "subtext1": "#b8c0e0",
        "subtext0": "#a5adcb",
        "overlay2": "#939ab7",
        "overlay1": "#8087a2",
        "overlay0": "#6e738d",
        "surface2": "#5b6078",
        "surface1": "#494d64",
        "surface0": "#363a4f",
        "base": "#24273a",
        "mantle": "#1e2030",
        "crust": "#181926",
    },
    "mocha": CATPPUCCIN_MOCHA,
}

# These names describe the Blox roles that replace the source palette. The
# source has more colour names than Blox, so related tones share one role.
PALETTE_ROLES = {
    "rosewater": "danger",
    "flamingo": "danger",
    "pink": "mauve",
    "mauve": "accent",
    "red": "danger",
    "maroon": "danger",
    "peach": "warning",
    "yellow": "warning",
    "green": "success",
    "teal": "teal",
    "sky": "info",
    "sapphire": "info",
    "blue": "info",
    "lavender": "mauve",
    "text": "foreground",
    "subtext1": "muted",
    "subtext0": "muted",
    "overlay2": "border",
    "overlay1": "muted",
    "overlay0": "surface_alt",
    "surface2": "surface_alt",
    "surface1": "surface",
    "surface0": "surface",
    "base": "background",
    "mantle": "surface",
    "crust": "surface_alt",
}

HEX_COLOUR = re.compile(r"#[0-9a-f]{6}\b", re.IGNORECASE)
ENCODED_HEX_COLOUR = re.compile(r"%23([0-9a-f]{6})\b", re.IGNORECASE)
RGB_COLOUR = re.compile(
    r"(?P<kind>rgba?)\(\s*(?P<red>\d+)\s*,\s*(?P<green>\d+)\s*,\s*(?P<blue>\d+)"
    r"(?P<alpha>\s*,\s*[^)]+)?\s*\)",
    re.IGNORECASE,
)


def _source_root() -> Path:
    return themes_dir() / SOURCE_ROOT_NAME


def _source_manifest() -> dict[str, Any]:
    path = _source_root() / "manifest.json"
    manifest = load_json(path)
    if manifest.get("upstream", {}).get("revision") != CATPPUCCIN_REVISION:
        raise RuntimeError(f"Catppuccin source revision is not pinned to {CATPPUCCIN_REVISION}: {path}")
    if not manifest.get("styles"):
        raise RuntimeError(f"Catppuccin source manifest contains no compiled styles: {path}")
    return manifest


def _palette_replacements(theme: dict[str, Any]) -> tuple[dict[str, str], dict[tuple[int, int, int], tuple[int, int, int]]]:
    colours = theme["colours"]
    hexes = {
        source.lower(): colours[PALETTE_ROLES[token]].lower()
        for palette in CATPPUCCIN_PALETTES.values()
        for token, source in palette.items()
    }
    rgb = {
        tuple(int(source[index:index + 2], 16) for index in (1, 3, 5)): tuple(int(target[index:index + 2], 16) for index in (1, 3, 5))
        for source, target in hexes.items()
    }
    return hexes, rgb


def _map_palette(css: str, theme: dict[str, Any]) -> str:
    hexes, rgb = _palette_replacements(theme)

    def replace_hex(match: re.Match[str]) -> str:
        return hexes.get(match.group(0).lower(), match.group(0).lower())

    mapped = HEX_COLOUR.sub(replace_hex, css)

    def replace_encoded_hex(match: re.Match[str]) -> str:
        replacement = hexes.get(f"#{match.group(1).lower()}")
        return f"%23{replacement[1:]}" if replacement else match.group(0).lower()

    mapped = ENCODED_HEX_COLOUR.sub(replace_encoded_hex, mapped)

    def replace_rgb(match: re.Match[str]) -> str:
        source = tuple(int(match.group(name)) for name in ("red", "green", "blue"))
        target = rgb.get(source)
        if target is None:
            return match.group(0)
        alpha = match.group("alpha") or ""
        return f"{match.group('kind').lower()}({target[0]}, {target[1]}, {target[2]}{alpha})"

    return RGB_COLOUR.sub(replace_rgb, mapped)


def _style_set(theme: dict[str, Any]) -> str:
    value = theme.get("stylus", {}).get("style_set", "recommended")
    if value not in STYLE_SET_VALUES:
        raise ValueError(f"unsupported Stylus style set: {value}")
    return value


def _style_is_recommended(record: dict[str, Any]) -> bool:
    return not record.get("unmaintained", False) and not record.get("remote_imports", [])


def _selected_records(source: dict[str, Any], style_set: str) -> list[dict[str, Any]]:
    records = source["styles"]
    if style_set == "all":
        return records
    if style_set == "unmaintained":
        return [record for record in records if not record.get("remote_imports", [])]
    return [record for record in records if _style_is_recommended(record)]


def _style_set_counts(source: dict[str, Any]) -> dict[str, int]:
    return {
        value: len(_selected_records(source, value))
        for value in STYLE_SET_VALUES
    }


def _generated_manifest(source: dict[str, Any], theme: dict[str, Any]) -> str:
    style_set = _style_set(theme)
    selected = _selected_records(source, style_set)
    output = {
        "schema_version": 1,
        "package": source["package"],
        "theme_id": theme["id"],
        "style_set": style_set,
        "style_set_counts": _style_set_counts(source),
        "upstream": copy.deepcopy(source["upstream"]),
        "styles": [
            {key: record[key] for key in ("id", "name", "version", "source", "document_blocks", "unmaintained", "remote_imports")}
            for record in selected
        ],
        "excluded": copy.deepcopy(source["excluded"]),
        "palette_mapping": copy.deepcopy(PALETTE_ROLES),
    }
    return canonical_json(output)


def render_stylus(theme: dict[str, Any]) -> str:
    source = _source_manifest()
    root = _source_root()
    selected = _selected_records(source, _style_set(theme))
    header = "\n".join([
        "/* ==UserStyle==",
        "@name Blox Web Theme",
        "@namespace blox.local/userstyles",
        "@version 1.0.0",
        "@description Site-scoped web styles generated from Catppuccin Userstyles and mapped to the active Blox theme.",
        "@author Blox",
        "@license MIT",
        "==/UserStyle== */",
        f"/* Source: {SOURCE_URL} at {CATPPUCCIN_REVISION}. */",
    ])
    chunks = [header]
    for record in selected:
        template = root / record["template"]
        try:
            css = template.read_text(encoding="utf-8")
        except OSError as error:
            raise RuntimeError(f"compiled Catppuccin style is missing: {template}") from error
        chunks.append(f"/* Site: {record['id']} · {record['name']} */\n{_map_palette(css, theme).rstrip()}")
    return "\n\n".join(chunks) + "\n"


def render_stylus_manifest(theme: dict[str, Any]) -> str:
    return _generated_manifest(_source_manifest(), theme)
