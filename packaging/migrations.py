"""Forward-only user-data migrations with pre-image backups.

Each migration copies the files it is about to change into
`$XDG_STATE_HOME/blox/backups/<stamp>/migrations/<id>/` before it runs, and
appends one ledger line per run. Rollback restores the most recent pre-image
for every applied migration of the generation being rolled back.
"""

from __future__ import annotations

import json
import shutil
import time
from pathlib import Path
from typing import Any, Callable

from layout import Roots


class Migration:
    def __init__(self, identifier: str, description: str, run: Callable[[Roots, Path], dict[str, Any]]):
        self.id = identifier
        self.description = description
        self.run = run


def _legacy_config(name: str) -> Path:
    return Path.home() / ".config" / "quickshell" / "blox" / name


def _copy_if_present(source: Path, destination: Path, backup_dir: Path) -> dict[str, Any] | None:
    if not source.is_file() or destination.exists():
        return None
    destination.parent.mkdir(parents=True, exist_ok=True)
    pre_image = backup_dir / destination.name
    pre_image.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(destination if destination.exists() else source, pre_image)
    shutil.copy2(source, destination)
    return {"source": str(source), "destination": str(destination), "pre_image": str(pre_image)}


def migrate_calendar_config(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    detail = _copy_if_present(_legacy_config("calendar.json"), roots.config / "calendar.json", backup_dir)
    return {"moved": bool(detail), "detail": detail}


def migrate_shell_env(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    detail = _copy_if_present(_legacy_config("env"), roots.config / "env", backup_dir)
    return {"moved": bool(detail), "detail": detail}


MIGRATIONS: list[Migration] = [
    Migration("calendar-config-xdg", "Move the calendar allow-list into $XDG_CONFIG_HOME/blox.", migrate_calendar_config),
    Migration("shell-env-config", "Move the personal shell environment file into $XDG_CONFIG_HOME/blox.", migrate_shell_env),
]


def _append_ledger(roots: Roots, entry: dict[str, Any]) -> None:
    with roots.migrations_ledger.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")


def read_ledger(roots: Roots) -> list[dict[str, Any]]:
    if not roots.migrations_ledger.is_file():
        return []
    entries: list[dict[str, Any]] = []
    for line in roots.migrations_ledger.read_text(encoding="utf-8").splitlines():
        try:
            entries.append(json.loads(line))
        except ValueError:
            continue
    return entries


def run_migrations(roots: Roots, from_version: str, to_version: str) -> list[dict[str, Any]]:
    stamp = time.strftime("%Y%m%dT%H%M%S")
    results: list[dict[str, Any]] = []
    for migration in MIGRATIONS:
        backup_dir = roots.backups / stamp / "migrations" / migration.id
        backup_dir.mkdir(parents=True, exist_ok=True)
        detail = migration.run(roots, backup_dir)
        entry = {
            "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "from": from_version,
            "to": to_version,
            "migration": migration.id,
            "pre_image": str(backup_dir),
            "result": "applied" if detail.get("moved") else "nothing-to-do",
            "detail": detail.get("detail"),
        }
        _append_ledger(roots, entry)
        results.append(entry)
    return results


def restore_pre_images(roots: Roots) -> list[str]:
    restored: list[str] = []
    for entry in reversed(read_ledger(roots)):
        if entry.get("result") != "applied":
            continue
        detail = entry.get("detail") or {}
        pre_image = detail.get("pre_image")
        destination = detail.get("destination")
        if not pre_image or not destination:
            continue
        source = Path(pre_image)
        target = Path(destination)
        if source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            restored.append(destination)
        entry["result"] = "restored"
        _append_ledger(roots, {**entry})
    return restored
