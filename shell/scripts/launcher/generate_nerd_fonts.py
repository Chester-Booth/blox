#!/usr/bin/env python3
"""Build the Nerd Font picker data from Nerd Fonts' glyphnames.json."""

import argparse
import json
import re
import urllib.request
from pathlib import Path


SOURCES = {
    "cod": ("Codicons", ["codicons", "vscode", "visual studio code"]),
    "custom": ("Custom", ["custom icons"]),
    "dev": ("Devicons", ["devicons", "developer icons"]),
    "extra": ("Extra", ["extra icons"]),
    "fa": ("Font Awesome", ["font awesome", "fontawesome"]),
    "fae": ("Font Awesome Extension", ["font awesome extension", "fontawesome extension"]),
    "iec": ("IEC Power Symbols", ["iec", "power symbols"]),
    "indent": ("Indentation", ["indentation"]),
    "indentation": ("Indentation", ["indentation"]),
    "linux": ("Font Logos", ["font logos", "linux", "distro"]),
    "md": ("Material Design", ["material design", "material design icons", "mdi"]),
    "oct": ("Octicons", ["octicons", "github"]),
    "pl": ("Powerline", ["powerline"]),
    "ple": ("Powerline Extra", ["powerline extra", "powerline"]),
    "pom": ("Pomicons", ["pomicons"]),
    "seti": ("Seti UI", ["seti ui", "seti"]),
    "weather": ("Weather Icons", ["weather icons", "weather"]),
}

SOURCE_FILTERS = [
    ("cod", "Codicons", ["cod"]),
    ("custom", "Custom & extra", ["custom", "extra"]),
    ("dev", "Devicons", ["dev"]),
    ("fa", "Font Awesome", ["fa", "fae"]),
    ("terminal", "Terminal & Powerline", ["iec", "indent", "indentation", "pl", "ple", "pom"]),
    ("linux", "Font Logos", ["linux"]),
    ("md", "Material Design", ["md"]),
    ("oct", "Octicons", ["oct"]),
    ("seti", "Seti UI", ["seti"]),
    ("weather", "Weather Icons", ["weather"]),
]

PURPOSES = [
    ("files", "Files & folders", {
        "archive", "attachment", "document", "file", "folder", "save", "storage",
        "upload", "download", "database", "clipboard", "copy", "paste", "trash",
    }),
    ("arrows", "Arrows & layout", {
        "align", "arrow", "chevron", "collapse", "direction", "expand", "indent",
        "layout", "move", "resize", "rotate", "sort", "swap", "unfold",
    }),
    ("development", "Development & brands", {
        "api", "app", "bitbucket", "branch", "bug", "code", "commit", "console",
        "debug", "developer", "docker", "git", "github", "gitlab", "language",
        "linux", "package", "programming", "pull request", "repo", "source", "webhook",
    }),
    ("terminal", "Terminal & Powerline", {
        "command", "indentation", "powerline", "prompt", "shell", "terminal",
    }),
    ("communication", "Communication", {
        "bell", "calendar", "call", "chat", "comment", "contact", "email", "inbox",
        "mail", "message", "notification", "phone", "rss", "send", "share",
    }),
    ("media", "Media", {
        "audio", "camera", "film", "headphone", "image", "media", "microphone",
        "music", "pause", "photo", "play", "podcast", "record", "skip", "stop",
        "video", "volume",
    }),
    ("devices", "Devices & hardware", {
        "battery", "bluetooth", "cpu", "desktop", "device", "display", "hardware",
        "keyboard", "laptop", "memory", "mobile", "monitor", "mouse", "printer",
        "router", "server", "sim", "tablet", "usb", "wifi",
    }),
    ("status", "Status & security", {
        "alert", "badge", "check", "error", "help", "info", "key", "lock", "security",
        "shield", "star", "success", "warning", "verified", "visibility",
    }),
    ("weather", "Weather & nature", {
        "cloud", "day", "earth", "fire", "flower", "leaf", "moon", "nature", "night",
        "rain", "snow", "storm", "sun", "temperature", "tree", "water", "weather", "wind",
    }),
    ("interface", "Interface & controls", set()),
]

SOURCE_DEFAULTS = {
    "cod": "development", "custom": "interface", "dev": "development",
    "extra": "interface", "iec": "devices", "indent": "terminal",
    "indentation": "terminal", "linux": "development", "pl": "terminal",
    "ple": "terminal", "pom": "terminal", "seti": "development",
    "weather": "weather",
}


def load_document(source: str):
    if source.startswith(("https://", "http://")):
        with urllib.request.urlopen(source) as response:
            return json.load(response)
    return json.loads(Path(source).read_text(encoding="utf-8"))


def source_key(identifier: str) -> str:
    return identifier.split("-", 1)[0]


def words(identifier: str) -> list[str]:
    glyph_name = identifier.split("-", 1)[1] if "-" in identifier else identifier
    return [word for word in re.split(r"[_-]+", glyph_name.lower()) if word]


def purpose_for(identifier: str, source: str) -> str:
    parts = words(identifier)
    phrase = " ".join(parts)
    terms = set(parts)
    for key, _title, keywords in PURPOSES[:-1]:
        if any(keyword in terms or (" " in keyword and keyword in phrase) for keyword in keywords):
            return key
    return SOURCE_DEFAULTS.get(source, "interface")


def build(source: str) -> dict:
    document = load_document(source)
    metadata = document.pop("METADATA")
    source_counts = {key: 0 for key in SOURCES}
    items = []
    for raw_identifier, glyph in document.items():
        source = source_key(raw_identifier)
        if source not in SOURCES:
            raise ValueError(f"Unknown Nerd Font source prefix: {source}")
        source_counts[source] += 1
        identifier = f"nf-{raw_identifier}"
        glyph_words = words(raw_identifier)
        phrase = " ".join(glyph_words)
        aliases = SOURCES[source][1]
        search_terms = list(dict.fromkeys([
            identifier, raw_identifier, "nerd font", "nerdfont", "nf",
            SOURCES[source][0].lower(), *aliases, phrase, *glyph_words,
        ]))
        items.append({
            "value": glyph["char"],
            "baseValue": glyph["char"],
            "name": phrase.capitalize(),
            "identifier": identifier,
            "keywords": " ".join(search_terms),
            "category": "Nerd Fonts",
            "subcategory": purpose_for(raw_identifier, source),
            "source": source,
            "fontFamily": "Symbols Nerd Font",
            "kind": "nerd-font",
        })

    return {
        "schema_version": 1,
        "nerd_fonts_version": metadata["version"],
        "source": "https://github.com/ryanoasis/nerd-fonts/blob/v3.4.0/glyphnames.json",
        "font_family": "Symbols Nerd Font",
        "sources": [
            {"key": key, "title": title, "tags": tags, "count": source_counts[key]}
            for key, (title, tags) in SOURCES.items()
            if source_counts[key]
        ],
        "source_filters": [
            {
                "key": key,
                "title": title,
                "keys": keys,
                "count": sum(source_counts[source] for source in keys),
            }
            for key, title, keys in SOURCE_FILTERS
        ],
        "purposes": [
            {"key": key, "title": title}
            for key, title, _keywords in PURPOSES
        ],
        "items": items,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="A local glyphnames.json path or URL")
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    output = build(arguments.source)
    arguments.output.write_text(
        json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
