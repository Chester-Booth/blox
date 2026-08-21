#!/usr/bin/env python3
"""Generate the tracked launcher emoji dataset from Unicode emoji-test.txt."""

import argparse
import json
import re
import xml.etree.ElementTree as ElementTree
from pathlib import Path


CATEGORY_ORDER = (
    "Smileys & Emotion",
    "People & Body",
    "Animals & Nature",
    "Food & Drink",
    "Activities",
    "Travel & Places",
    "Objects",
    "Flags",
    "Symbols",
)

SMILEY_SUBGROUP_ORDER = (
    "face-smiling",
    "face-affection",
    "face-tongue",
    "face-hand",
    "face-neutral-skeptical",
    "face-sleepy",
    "face-unwell",
    "face-hat",
    "face-glasses",
    "face-concerned",
    "face-negative",
    "cat-face",
    "face-costume",
    "monkey-face",
    "heart",
    "emotion",
)

COMMON_SYMBOL_ORDER = (
    "‽", "¡", "¿", "§", "¶", "†", "‡", "※", "⁂", "⁎",
    "№", "℗", "℠", "℡", "℻",
    "♔", "♕", "♖", "♗", "♘", "♙", "♚", "♛", "♜", "♝", "♞",
)
SKIN_TONES = "🏻🏼🏽🏾🏿"


def tone_metadata(value: str) -> tuple[str, int]:
    tones = {SKIN_TONES.index(character) + 1 for character in value if character in SKIN_TONES}
    base_value = "".join(character for character in value if character not in SKIN_TONES)
    return base_value, tones.pop() if len(tones) == 1 else (-1 if tones else 0)


def symbol_subcategory(value: str, name: str, general_category: str) -> tuple[str, int]:
    if value in COMMON_SYMBOL_ORDER:
        return "text-common", COMMON_SYMBOL_ORDER.index(value)
    if "ARROW" in name or 0x2190 <= ord(value) <= 0x21FF:
        return "text-arrow", ord(value)
    if general_category == "Sm" or "INTEGRAL" in name or "SUMMATION" in name:
        return "text-maths", ord(value)
    if any(word in name for word in (
        "SQUARE", "CIRCLE", "TRIANGLE", "DIAMOND", "RECTANGLE", "ELLIPSE", "LOZENGE",
        "POLYGON", "STAR", "ARC", "CORNER", "BOX DRAWINGS", "BLOCK", "SHADE",
    )):
        return "text-shape", ord(value)
    if general_category == "Sc":
        return "text-currency", ord(value)
    if general_category.startswith("P"):
        return "text-punctuation", ord(value)
    return "text-other", ord(value)


def item_sort_key(item: dict) -> tuple[int, int, int]:
    category = item["category"]
    category_order = CATEGORY_ORDER.index(category) if category in CATEGORY_ORDER else len(CATEGORY_ORDER)
    subgroup = item["subcategory"]
    if category == "Smileys & Emotion":
        subgroup_order = SMILEY_SUBGROUP_ORDER.index(subgroup) if subgroup in SMILEY_SUBGROUP_ORDER else len(SMILEY_SUBGROUP_ORDER)
        return category_order, subgroup_order, item["_order"]
    if category == "Symbols" and subgroup.startswith("text-"):
        subgroup_order = {
            "text-common": 1,
            "text-punctuation": 2,
            "text-shape": 3,
            "text-arrow": 4,
            "text-maths": 5,
            "text-currency": 6,
            "text-other": 7,
        }[subgroup]
        return category_order, subgroup_order, item["_suborder"]
    return category_order, 0, item["_order"]


def read_annotations(paths: list[Path]) -> dict[str, dict[str, str]]:
    annotations: dict[str, dict[str, str]] = {}
    for path in paths:
        if not path:
            continue
        for element in ElementTree.parse(path).iterfind(".//annotation"):
            value = element.attrib.get("cp", "")
            if not value or not element.text:
                continue
            entry = annotations.setdefault(value, {"name": "", "keywords": ""})
            text = " ".join(element.text.split())
            if element.attrib.get("type") == "tts":
                entry["name"] = text
            else:
                entry["keywords"] = " ".join(part.strip() for part in text.split("|") if part.strip())
    return annotations


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("unicode_data", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--annotations", type=Path)
    parser.add_argument("--annotations-derived", type=Path)
    parser.add_argument("--cldr-version", default="")
    args = parser.parse_args()
    annotations = read_annotations([args.annotations, args.annotations_derived])
    group = ""
    subgroup = ""
    items = []
    version = ""
    for line in args.source.read_text(encoding="utf-8").splitlines():
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        elif line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
        elif line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
        elif "; fully-qualified" in line:
            match = re.match(r"^([0-9A-F ]+)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$", line)
            if not match:
                continue
            value = match.group(2)
            annotation = annotations.get(value, annotations.get(value.replace("\ufe0f", ""), {}))
            name = annotation.get("name") or match.group(3)
            keywords = annotation.get("keywords") or match.group(3).replace("-", " ")
            base_value, tone = tone_metadata(value)
            items.append({
                "value": value,
                "baseValue": base_value,
                "tone": tone,
                "name": name,
                "keywords": keywords,
                "category": group,
                "subcategory": subgroup,
                "_order": len(items),
                "_suborder": len(items),
            })
    emoji_values = {item["value"] for item in items}
    emoji_text_forms = {value.replace("\ufe0f", "").replace("\ufe0e", "") for value in emoji_values}
    symbol_ranges = (
        (0x00A1, 0x00BF),
        (0x2010, 0x206F),
        (0x20A0, 0x20CF),
        (0x2100, 0x218F),
        (0x2190, 0x2BFF),
    )
    for line in args.unicode_data.read_text(encoding="utf-8").splitlines():
        fields = line.split(";")
        if len(fields) < 3 or not fields[1] or not fields[2].startswith(("S", "P")):
            continue
        codepoint = int(fields[0], 16)
        if not any(start <= codepoint <= end for start, end in symbol_ranges):
            continue
        value = chr(codepoint)
        if value in emoji_values or value in emoji_text_forms or fields[1].startswith("<"):
            continue
        source_name = fields[1]
        name = source_name.lower().replace("-", " ")
        subgroup, suborder = symbol_subcategory(value, source_name, fields[2])
        items.append({
            "value": value,
            "baseValue": value,
            "tone": 0,
            "name": name,
            "keywords": name,
            "category": "Symbols",
            "subcategory": subgroup,
            "_order": len(items),
            "_suborder": suborder,
        })
    items.sort(key=item_sort_key)
    for item in items:
        del item["_order"]
        del item["_suborder"]
    document = {
        "schema_version": 1,
        "unicode_emoji_version": version,
        "source": "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
        "unicode_data_source": "https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt",
        "cldr_version": args.cldr_version,
        "cldr_annotation_source": "https://github.com/unicode-org/cldr/tree/release-48-2/common/annotations",
        "cldr_derived_annotation_source": "https://github.com/unicode-org/cldr/tree/release-48-2/common/annotationsDerived",
        "licence": "https://www.unicode.org/license.txt",
        "items": items,
    }
    args.output.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
