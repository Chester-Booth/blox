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
        # Older Blox versions could leave a second comma on its own line.
        # Accept it during migration; newly written members remain normal.
        if text[index] == ",":
            index += 1
            continue
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
        return _jsonc_loads(text[member.value_start : member.value_end])
    except json.JSONDecodeError as error:
        raise EditorSettingsFailure(f"owned settings value is not valid JSONC: {error}") from error


def _jsonc_loads(text: str) -> Any:
    """Decode a JSONC value without changing the source document."""
    output: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(text):
        character = text[index]
        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            output.append(character)
            index += 1
        elif text.startswith("//", index):
            newline = text.find("\n", index + 2)
            if newline < 0:
                break
            output.append("\n")
            index = newline + 1
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                raise json.JSONDecodeError("unterminated comment", text, index)
            comment = text[index:end + 2]
            output.extend("\n" if item == "\n" else " " for item in comment)
            index = end + 2
        else:
            output.append(character)
            index += 1
    without_comments = "".join(output)
    output = []
    index = 0
    in_string = False
    escaped = False
    while index < len(without_comments):
        character = without_comments[index]
        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            output.append(character)
            index += 1
            continue
        if character == ",":
            lookahead = index + 1
            while lookahead < len(without_comments) and without_comments[lookahead].isspace():
                lookahead += 1
            if lookahead < len(without_comments) and without_comments[lookahead] in "]}":
                index += 1
                continue
        output.append(character)
        index += 1
    return json.loads("".join(output))


def _settings_destination(settings: Path) -> Path:
    if not settings.is_symlink():
        return settings
    try:
        destination = settings.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise EditorSettingsFailure(f"cannot resolve symlinked editor settings: {settings}") from error
    if not destination.is_file():
        raise EditorSettingsFailure(f"editor settings symlink does not target a regular file: {settings}")
    return destination


def _settings_text(settings: Path) -> tuple[Path, str]:
    destination = _settings_destination(settings)
    return destination, destination.read_text(encoding="utf-8") if destination.exists() else "{}\n"


def read_settings_values(settings: Path, keys: list[str] | tuple[str, ...]) -> dict[str, dict[str, Any]]:
    """Read selected JSONC settings while retaining explicit key presence."""
    _, original = _settings_text(settings)
    parsed, _ = members(original)
    values: dict[str, dict[str, Any]] = {}
    for key in keys:
        member = parsed.get(key)
        values[key] = {"present": member is not None}
        if member is not None:
            values[key]["value"] = _decode(original, member)
    return values


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
        parsed, closing = members(text)
        if parsed:
            last = max(parsed.values(), key=lambda member: member.start)
            prefix = "" if last.comma_after is not None else ","
        else:
            prefix = ""
        entries = ",\n".join(
            f'  {json.dumps(key)}: {json.dumps(value, ensure_ascii=False)}'
            for key, value in missing
        )
        insertion = prefix + "\n" + entries + "\n"
        text = text[:closing] + insertion + text[closing:]
    return text


def remove_members(text: str, keys: list[str] | tuple[str, ...] | set[str]) -> str:
    """Remove top-level JSONC members while leaving other source text intact."""
    parsed, _ = members(text)
    removals = []
    for key in keys:
        member = parsed.get(key)
        if member is None:
            continue
        if member.comma_after is not None:
            start = member.start
            end = member.comma_after + 1
        else:
            previous = [candidate for candidate in parsed.values() if candidate.start < member.start]
            previous_member = max(previous, key=lambda candidate: candidate.start, default=None)
            start = previous_member.comma_after if previous_member and previous_member.comma_after is not None else member.start
            end = member.value_end
        removals.append((start, end))
    merged: list[tuple[int, int]] = []
    for start, end in sorted(removals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    for start, end in reversed(merged):
        text = text[:start] + text[end:]
    _, closing = members(text)
    trimmed_end = closing
    while trimmed_end > 0 and text[trimmed_end - 1].isspace():
        trimmed_end -= 1
    if trimmed_end > 0 and text[trimmed_end - 1] == ",":
        text = text[:trimmed_end - 1] + text[trimmed_end:]
    return text


def _write_settings(destination: Path, updated: str, atomic: bool = True) -> None:
    if not atomic and destination.exists():
        # Zed 1.17 watches the settings file inode. Keep that inode when its
        # settings change so an open window continues to receive file events.
        with destination.open("r+", encoding="utf-8") as handle:
            handle.seek(0)
            handle.write(updated)
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
        return
    normalised: list[str] = []
    for line in updated.splitlines(keepends=True):
        if line.strip() == ",":
            previous = "".join(normalised).rstrip()
            if previous.endswith(","):
                continue
        normalised.append(line)
    updated = "".join(normalised)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.tmp"
    with temporary.open("x", encoding="utf-8") as handle:
        handle.write(updated)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, destination)


def apply_fragment(settings: Path, fragment: dict[str, Any], atomic: bool = True) -> None:
    destination, original = _settings_text(settings)
    parsed, _ = members(original)
    updates = {key: value for key, value in fragment.items() if key != "workbench.colorCustomizations"}
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
    _write_settings(destination, updated, atomic=atomic)


def restore_settings(settings: Path, values: dict[str, Any], remove: list[str] | tuple[str, ...] = (), atomic: bool = True) -> None:
    """Restore or remove selected top-level settings atomically."""
    destination, original = _settings_text(settings)
    updated = merge_members(original, values) if values else original
    if remove:
        updated = remove_members(updated, remove)
    _write_settings(destination, updated, atomic=atomic)
