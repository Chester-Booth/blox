#!/usr/bin/env python3
"""Read generated-file provenance for the Settings Targets & files page."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

PRODUCT_ROOT = Path(__file__).resolve().parents[2]
if str(PRODUCT_ROOT) not in sys.path:
    sys.path.insert(0, str(PRODUCT_ROOT))

from themes.lib.blox_theme.composition import CompositionDocument, targets_and_files, observe_component, component_digest
from themes.lib.blox_theme.runtime import current_generation, RuntimeFailure
from themes.lib.blox_theme.apply_owners import _target_observation
from shell.scripts.settings_document import SettingsDocument
from shell.scripts.hyprland_settings import HyprlandSettingsOwner


def observe_ledger(ledger: dict[str, Any]) -> dict[str, Any]:
    """Project current owner evidence without advancing a transaction's ledger."""
    settings = SettingsDocument().get()
    if not settings.ok:
        for component in ledger["components"]:
            ledger = observe_component(ledger, component, state="unavailable")
        return ledger
    try:
        module = HyprlandSettingsOwner(SettingsDocument().root).capture_preimage()["hyprland-settings.lua"]
        digest = component_digest({"settings": settings.data, "module": module})
        ledger = observe_component(ledger, "theme-metadata", digest=digest, revision=settings.revision)
    except (OSError, ValueError, RuntimeFailure, KeyError):
        ledger = observe_component(ledger, "theme-metadata", state="unavailable")
    grouped = {"appearance": {}, "wallpaper": {}, "widgets": {}}
    for target, item in settings.data["targets"].items():
        if item["enabled"]:
            component = "wallpaper" if target == "wallpaper" else "widgets" if target == "widgets" else "appearance"
            try:
                grouped[component][target] = _target_observation(target)
            except (OSError, ValueError, RuntimeFailure, KeyError):
                grouped[component][target] = {"digest": None, "revision": None}
    for component, evidence in grouped.items():
        prior = ledger["components"][component]
        # Generated files alone cannot prove that an application loaded them.
        state = "unavailable" if any(item["digest"] is None for item in evidence.values()) else "pending" if prior["status"] == "pending" else None
        ledger = observe_component(ledger, component, digest=component_digest(evidence), state=state)
    for component in set(ledger["components"]) - {"theme-metadata", "appearance", "wallpaper", "widgets"}:
        # Stored receipts do not substitute for a runtime owner observation.
        ledger = observe_component(ledger, component)
    return ledger


def read_provenance() -> dict[str, Any]:
    """Return validated ledger state and the active generation's file records."""
    ledger = observe_ledger(CompositionDocument().read())
    generation = current_generation()
    targets = []
    generation_data = None
    if generation is not None:
        path, manifest = generation
        targets = targets_and_files(path, manifest)
        for target in targets:
            for file in target["files"]:
                relative = Path(file["path"]).resolve().relative_to(Path(path).resolve())
                file["relativePath"] = relative.as_posix()
                file["name"] = relative.name
        generation_data = {
            "id": manifest["generation_id"],
            "themeId": manifest["theme_id"],
            "createdAt": manifest["created_at"],
            "sourceDigest": manifest["source_sha256"],
        }
    return {
        "ledgerRevision": ledger["revision"],
        "observedAt": ledger["observedAt"],
        "components": ledger["components"],
        "activeTheme": ledger["activeTheme"],
        "generation": generation_data,
        "targets": targets,
    }


def main() -> int:
    try:
        print(json.dumps({"version": 1, "ok": True, "code": "ok", "data": read_provenance()},
                         separators=(",", ":"), sort_keys=True))
        return 0
    except Exception as error:
        print(json.dumps({"version": 1, "ok": False, "code": "unavailable",
                          "message": str(error), "data": None},
                         separators=(",", ":"), sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
