#!/usr/bin/env python3
"""Runtime action owner for the revisioned Settings document."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any

# The validator fallback lives in the adjacent installed themes package.
PRODUCT_ROOT = Path(__file__).resolve().parents[2]
if str(PRODUCT_ROOT) not in sys.path:
    sys.path.insert(0, str(PRODUCT_ROOT))

try:
    from .settings_document import CURRENT_VERSION, SettingsDocument, SettingsResult
except ImportError:  # Executed as the shell-owned runtime script.
    from settings_document import CURRENT_VERSION, SettingsDocument, SettingsResult


def _action(ok: bool, code: str, message: str, data: dict[str, Any]) -> dict[str, Any]:
    return {
        "version": 1,
        "ok": ok,
        "code": code,
        "message": message,
        "data": data,
    }


def _public_code(code: str) -> str:
    return {
        "unsafe": "permission-denied",
        "invalid": "invalid-data",
        "invalid-path": "invalid-data",
        "interrupted": "internal",
    }.get(code, code)


def _result_data(operation: str, result: SettingsResult) -> tuple[dict[str, Any], str, str]:
    code = _public_code(result.code)
    settings = result.data if isinstance(result.data, dict) else None
    current_revision = result.revision
    if not isinstance(current_revision, int) and isinstance(result.before_revision, int):
        current_revision = result.before_revision
    if not isinstance(current_revision, int) and settings is not None:
        current_revision = settings.get("revision")

    before_revision = result.before_revision
    if not isinstance(before_revision, int):
        before_revision = current_revision
    after_revision = result.revision if result.committed else current_revision
    if operation == "get":
        before_revision = current_revision
        after_revision = current_revision

    if result.ok:
        message = ""
    elif code == "conflict":
        message = "settings revision conflict"
    else:
        message = str(result.data) if isinstance(result.data, str) else result.code
    data = {
        "schemaVersion": settings.get("schemaVersion", CURRENT_VERSION) if settings is not None else CURRENT_VERSION,
        "revision": current_revision,
        "beforeRevision": before_revision,
        "afterRevision": after_revision,
        "observedAt": result.observed_at or time.time(),
        "dirty": False,
        "conflict": code == "conflict",
        "changedComponents": list(result.changed),
        "commitState": "not-applicable" if operation == "get" else "committed" if result.committed else "not-committed",
        "rollbackState": "not-attempted",
        "error": None if result.ok else {"code": code, "message": message},
        "settings": settings,
    }
    return data, code, message


def _rejected(operation: str, code: str, message: str, document: SettingsDocument) -> dict[str, Any]:
    snapshot = document.get()
    revision = snapshot.revision if snapshot.ok else None
    settings = snapshot.data if snapshot.ok and isinstance(snapshot.data, dict) else None
    data = {
        "schemaVersion": settings.get("schemaVersion", CURRENT_VERSION) if settings else CURRENT_VERSION,
        "revision": revision,
        "beforeRevision": revision,
        "afterRevision": revision,
        "observedAt": snapshot.observed_at or time.time(),
        "dirty": False,
        "conflict": code == "conflict",
        "changedComponents": [],
        "commitState": "not-applicable" if operation == "get" else "not-committed",
        "rollbackState": "not-attempted",
        "error": {"code": code, "message": message},
        "settings": settings,
    }
    return _action(False, code, message, data)


def run_request(operation: str, request_json: str, document: SettingsDocument | None = None) -> dict[str, Any]:
    """Validate the owner request, then delegate all mutations to the document transaction."""
    store = document or SettingsDocument()
    try:
        request = json.loads(request_json)
    except (json.JSONDecodeError, TypeError):
        return _rejected(operation, "invalid-data", "settings request must be valid JSON", store)
    if not isinstance(request, dict):
        return _rejected(operation, "invalid-data", "settings request must be an object", store)

    if operation == "apply-widgets":
        expected = request.get("expectedRevision")
        if set(request) != {"expectedRevision"} or type(expected) is not int:
            return _rejected(operation, "invalid-data", "apply-widgets requires expectedRevision", store)
        from themes.lib.blox_theme.apply_owners import create_widget_apply
        from themes.lib.blox_theme.apply_coordinator import ApplyError
        try:
            coordinator, payload = create_widget_apply(expected)
            publication = coordinator.apply(payload)
            succeeded = publication["phase"] == "complete" and publication["code"] == "ok"
            if succeeded:
                receipt = coordinator.finish()
                publication = {**publication, "receipt": receipt}
                succeeded = not receipt.get("observationConflict", False)
            outcome = store.get()
            data, _, _ = _result_data("get", outcome)
            # Publication does not commit Settings or reconcile the window's drafts.
            data["settings"] = None
            data["widgetApply"] = publication
            code = "ok" if succeeded else "internal"
            message = "" if succeeded else publication.get("error") or "widget publication failed"
            data["error"] = None if succeeded else {"code": code, "message": message}
            return _action(succeeded, code, message, data)
        except (ApplyError, ValueError, OSError) as error:
            message = str(error)
            code = "conflict" if "revision conflict" in message else "busy" if "previous Apply" in message else "invalid-data"
            action = _rejected(operation, code, message, store)
            action["data"]["settings"] = None
            return action

    if operation.startswith("bundle-"):
        from shell.scripts.bundle_runtime import run as run_bundle
        before = store.get()
        try:
            bundle = run_bundle(operation.removeprefix("bundle-"), request, store)
        except Exception as error:
            return _rejected(operation, "invalid-data", str(error), store)
        after = store.get()
        outcome = SettingsResult(True, "ok", after.data, after.revision, before.revision,
                                 tuple(bundle.get("changedComponents", [])),
                                 committed=after.revision != before.revision, observed_at=after.observed_at)
        data, code, message = _result_data(operation if outcome.committed else "get", outcome)
        data["bundle"] = bundle
        return _action(True, code, message, data)
    if operation == "get":
        outcome = store.get()
    elif operation == "set-sections":
        expected = request.get("expectedRevision")
        sections = request.get("sections")
        if type(expected) is not int or not isinstance(sections, dict) or not sections:
            return _rejected(operation, "invalid-data", "set-sections requires sections and expectedRevision", store)
        outcome = store.update_sections(sections, expected)
    elif operation == "set":
        path = request.get("path")
        expected = request.get("expectedRevision")
        raw_value = request.get("valueJson")
        if not isinstance(path, str) or not isinstance(raw_value, str) or type(expected) is not int:
            return _rejected(operation, "invalid-data", "set requires path, valueJson and expectedRevision", store)
        try:
            if path == "widgets":
                from themes.lib.blox_theme.core import widget_model
                value = widget_model().parse_profile(raw_value)
            else:
                value = json.loads(raw_value)
        except ValueError as error:
            return _rejected(operation, "invalid-data", str(error) if path == "widgets" else "set value must be valid JSON", store)
        outcome = store.set(path, value, expected)
    elif operation == "reset":
        expected = request.get("expectedRevision")
        section = request.get("section")
        if type(expected) is not int or (section is not None and not isinstance(section, str)):
            return _rejected(operation, "invalid-data", "reset requires an expectedRevision and optional section", store)
        outcome = store.reset(expected, section)
    else:
        return _rejected(operation, "usage", f"unknown settings operation: {operation}", store)

    data, code, message = _result_data(operation, outcome)
    return _action(outcome.ok, code, message, data)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 2:
        action = _rejected("get", "usage", "Use: settings_runtime.py {get|set|reset} REQUEST_JSON", SettingsDocument())
    else:
        action = run_request(arguments[0], arguments[1])
    print(json.dumps(action, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
