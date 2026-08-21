from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any


EXECUTABLE_WIDGET_FIELDS = (
    "content_command",
    "left_click_command",
    "right_click_command",
)
TRUST_SCHEMA_VERSION = 1
SAFE_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


class TrustFailure(ValueError):
    pass


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _field_paths(widgets: dict[str, Any]) -> list[str]:
    fields: list[str] = []
    for index, item in enumerate(widgets.get("items", [])):
        if not isinstance(item, dict):
            continue
        for field in EXECUTABLE_WIDGET_FIELDS:
            if isinstance(item.get(field), str) and item[field]:
                fields.append(f"widgets.items[{index}].{field}")
    return fields


def strip_widget_commands(theme: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Return an imported copy with every executable widget field disabled."""
    sanitised = copy.deepcopy(theme)
    widgets = sanitised.get("widgets")
    if not isinstance(widgets, dict):
        return sanitised, []
    fields = _field_paths(widgets)
    for item in widgets.get("items", []):
        if not isinstance(item, dict):
            continue
        for field in EXECUTABLE_WIDGET_FIELDS:
            if field in item:
                item[field] = ""
    return sanitised, fields


def strip_widget_document(document: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Apply the same import rule to a detached widget document."""
    widgets = document.get("widgets")
    if not isinstance(widgets, dict):
        return copy.deepcopy(document), []
    sanitised_widgets, fields = strip_widget_commands({"widgets": widgets})
    sanitised = copy.deepcopy(document)
    sanitised["widgets"] = sanitised_widgets["widgets"]
    return sanitised, [field.removeprefix("widgets.") for field in fields]


def trust_directory(library: Path) -> Path:
    return library / "trust" / "themes"


def trust_record_path(library: Path, theme_id: str) -> Path:
    if not SAFE_ID.fullmatch(theme_id):
        raise TrustFailure(f"theme id is not safe for trust metadata: {theme_id}")
    return trust_directory(library) / f"{theme_id}.json"


def write_trust_record(
    library: Path,
    theme_id: str,
    source_sha256: str,
    content_sha256: str,
    executable_fields: list[str],
) -> Path:
    destination = trust_record_path(library, theme_id)
    if not re.fullmatch(r"[0-9a-f]{64}", source_sha256) or not re.fullmatch(r"[0-9a-f]{64}", content_sha256):
        raise TrustFailure("trust metadata requires SHA-256 digests")
    document = {
        "schema_version": TRUST_SCHEMA_VERSION,
        "kind": "theme-trust",
        "id": theme_id,
        "source_sha256": source_sha256,
        "content_sha256": content_sha256,
        "trusted": False,
        "executable_fields": sorted(executable_fields),
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{theme_id}-", suffix=".json", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def trust_record_allows_commands(theme_path: Path, library: Path) -> bool:
    """Check explicit consent and the exact saved source digest."""
    try:
        theme_id = theme_path.stem
        record = json.loads(trust_record_path(library, theme_id).read_text(encoding="utf-8"))
        return (
            record.get("schema_version") == TRUST_SCHEMA_VERSION
            and record.get("kind") == "theme-trust"
            and record.get("id") == theme_id
            and record.get("trusted") is True
            and record.get("content_sha256") == _digest(theme_path.read_bytes())
        )
    except (OSError, json.JSONDecodeError, TrustFailure):
        return False


def safe_template_output(root: Path, requested: str) -> Path:
    """Resolve one relative template output and reject traversal or symlink escape."""
    if not requested or "\\" in requested:
        raise TrustFailure("template output must be a non-empty relative path")
    raw = Path(requested)
    if raw.is_absolute() or ".." in raw.parts or "." in raw.parts or raw.parts == ():
        raise TrustFailure("template output must stay below its approved root")
    approved_root = root.expanduser().resolve()
    candidate = (approved_root / raw).resolve(strict=False)
    try:
        candidate.relative_to(approved_root)
    except ValueError as error:
        raise TrustFailure("template output escapes its approved root") from error
    if candidate.exists() and not candidate.is_file():
        raise TrustFailure("template output is not a regular file")
    return candidate


def write_template_output(root: Path, requested: str, content: str | bytes) -> Path:
    destination = safe_template_output(root, requested)
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = content.encode("utf-8") if isinstance(content, str) else content
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}-", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination
