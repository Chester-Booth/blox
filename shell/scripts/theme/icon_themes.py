#!/usr/bin/env python3
"""List installed icon themes and a few small preview files for the picker."""

from __future__ import annotations

import configparser
import json
import os
import re
from pathlib import Path


SAMPLE_ALIASES = {
    "folder": ("folder", "folder-open"),
    "document": ("text-x-generic", "document-open", "document"),
    "network": ("network-wireless", "network-wired", "network-server"),
    "audio": ("audio-headphones", "audio-speakers", "audio-x-generic"),
}
ICON_SUFFIXES = {".png", ".svg", ".xpm"}


def icon_roots() -> list[Path]:
    configured = os.environ.get("XDG_DATA_HOME")
    data_roots = [Path(configured).expanduser() if configured else Path.home() / ".local/share"]
    data_roots.extend(Path(value).expanduser() for value in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"))

    roots = [root / "icons" for root in data_roots]
    roots.extend((Path.home() / ".icons", Path.home() / ".local/share/icons"))
    result: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        resolved = root.resolve()
        if resolved not in seen and resolved.is_dir():
            seen.add(resolved)
            result.append(resolved)
    return result


def display_name(index_path: Path, fallback: str) -> str:
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    try:
        parser.read(index_path, encoding="utf-8")
        section = parser["Icon Theme"]
        return section.get("Name", fallback).strip() or fallback
    except (configparser.Error, OSError, KeyError):
        return fallback


def icon_stem(path: Path) -> str:
    stem = path.stem
    return stem.removesuffix("-symbolic")


def icon_score(path: Path) -> tuple[int, int, str]:
    parts = {part.casefold() for part in path.parts}
    symbolic = 1 if path.stem.endswith("-symbolic") else 0
    if "scalable" in parts:
        size_score = 0
    else:
        match = next((re.fullmatch(r"(\d+)x\d+", part) for part in path.parts), None)
        size_score = abs(int(match.group(1)) - 32) if match else 20
    vector_score = 0 if path.suffix.casefold() == ".svg" else 1
    return symbolic, size_score + vector_score, str(path)


def preview_files(theme_path: Path) -> dict[str, str]:
    found: dict[str, list[Path]] = {key: [] for key in SAMPLE_ALIASES}
    try:
        for directory, _, filenames in os.walk(theme_path):
            for filename in filenames:
                path = Path(directory) / filename
                if path.suffix.casefold() not in ICON_SUFFIXES:
                    continue
                stem = icon_stem(path)
                for sample, aliases in SAMPLE_ALIASES.items():
                    if stem in aliases:
                        found[sample].append(path)
    except OSError:
        return {}

    return {
        sample: str(min(paths, key=icon_score).resolve().as_uri())
        for sample, paths in found.items()
        if paths
    }


def installed_themes() -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    seen: set[str] = set()
    for root in icon_roots():
        try:
            candidates = sorted(root.iterdir(), key=lambda path: path.name.casefold())
        except OSError:
            continue
        for theme_path in candidates:
            if not theme_path.is_dir() or theme_path.name in seen:
                continue
            index_path = theme_path / "index.theme"
            if not index_path.is_file():
                continue
            samples = preview_files(theme_path)
            if not samples:
                continue
            seen.add(theme_path.name)
            entries.append({
                "id": theme_path.name,
                "name": display_name(index_path, theme_path.name),
                "samples": samples,
            })
    entries.sort(key=lambda entry: (str(entry["name"]).casefold(), str(entry["id"]).casefold()))
    return entries


if __name__ == "__main__":
    print(json.dumps({"themes": installed_themes()}, separators=(",", ":")))
