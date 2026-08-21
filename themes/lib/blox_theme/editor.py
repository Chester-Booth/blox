from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class EditorSettingsFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class Member:
    start: int
    value_start: int
    value_end: int
    comma_after: int | None


def _skip(text: str, index: int) -> int:
    while index < len(text):
        if text[index].isspace():
            index += 1
        elif text.startswith("//", index):
            end = text.find("\n", index + 2)
            index = len(text) if end < 0 else end + 1
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                raise EditorSettingsFailure("unterminated JSONC comment")
            index = end + 2
        else:
            break
    return index


def _string_end(text: str, start: int) -> int:
    index = start + 1
    while index < len(text):
        if text[index] == "\\":
            index += 2
        elif text[index] == '"':
            return index + 1
        else:
            index += 1
    raise EditorSettingsFailure("unterminated JSONC string")


def _value_end(text: str, start: int) -> int:
    depth = 0
    index = start
    while index < len(text):
        if text[index] == '"':
            index = _string_end(text, index)
            continue
        if text.startswith("//", index) or text.startswith("/*", index):
            index = _skip(text, index)
            continue
        character = text[index]
        if character in "[{":
            depth += 1
        elif character in "]}":
            if depth == 0:
                return index
            depth -= 1
        elif character == "," and depth == 0:
            return index
        index += 1
    raise EditorSettingsFailure("unterminated JSONC value")


def members(text: str) -> tuple[dict[str, Member], int]:
    index = _skip(text, 0)
    if index >= len(text) or text[index] != "{":
        raise EditorSettingsFailure("settings root must be a JSONC object")
    index += 1
    found: dict[str, Member] = {}
    while True:
        index = _skip(text, index)
        if index >= len(text):
            raise EditorSettingsFailure("unterminated settings object")
        if text[index] == "}":
            return found, index
        start = index
        if text[index] != '"':
            raise EditorSettingsFailure("settings keys must be quoted strings")
        key_end = _string_end(text, index)
        key = json.loads(text[index:key_end])
        index = _skip(text, key_end)
        if index >= len(text) or text[index] != ":":
            raise EditorSettingsFailure(f"missing colon after settings key {key!r}")
        value_start = _skip(text, index + 1)
        value_end = _value_end(text, value_start)
        after = _skip(text, value_end)
        comma = after if after < len(text) and text[after] == "," else None
        if key in found:
            raise EditorSettingsFailure(f"duplicate settings key: {key}")
        found[key] = Member(start, value_start, value_end, comma)
        index = comma + 1 if comma is not None else after


def _decode(text: str, member: Member) -> Any:
    try:
        return json.loads(text[member.value_start : member.value_end])
    except json.JSONDecodeError as error:
        raise EditorSettingsFailure(f"owned settings value is not strict JSON: {error}") from error


def merge_members(text: str, updates: dict[str, Any]) -> str:
    parsed, closing = members(text)
    replacements: list[tuple[int, int, str]] = []
    missing: list[tuple[str, Any]] = []
    for key, value in updates.items():
        member = parsed.get(key)
        if member is None:
            missing.append((key, value))
        else:
            replacements.append((member.value_start, member.value_end, json.dumps(value, ensure_ascii=False)))
    for start, end, value in sorted(replacements, reverse=True):
        text = text[:start] + value + text[end:]
    if missing:
        _, closing = members(text)
        prefix = "" if not members(text)[0] else ","
        insertion = prefix + "\n" + "\n".join(f'  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)},' for key, value in missing) + "\n"
        text = text[:closing] + insertion + text[closing:]
    return text


def apply_fragment(settings: Path, fragment: dict[str, Any]) -> None:
    destination = settings
    if settings.is_symlink():
        try:
            destination = settings.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise EditorSettingsFailure(f"cannot resolve symlinked editor settings: {settings}") from error
        if not destination.is_file():
            raise EditorSettingsFailure(f"editor settings symlink does not target a regular file: {settings}")
    original = destination.read_text(encoding="utf-8") if destination.exists() else "{}\n"
    parsed, _ = members(original)
    updates = {key: fragment[key] for key in ("workbench.colorTheme", "editor.fontFamily", "editor.fontSize")}
    if "workbench.colorCustomizations" in fragment:
        existing_workbench: dict[str, Any] = {}
        if "workbench.colorCustomizations" in parsed:
            decoded = _decode(original, parsed["workbench.colorCustomizations"])
            if not isinstance(decoded, dict):
                raise EditorSettingsFailure("workbench.colorCustomizations must be an object")
            existing_workbench = decoded
        existing_workbench.update(fragment["workbench.colorCustomizations"])
        updates["workbench.colorCustomizations"] = existing_workbench
    updated = merge_members(original, updates)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.tmp"
    with temporary.open("x", encoding="utf-8") as handle:
        handle.write(updated)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, destination)
