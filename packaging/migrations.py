"""Forward-only user-data migrations with pre-image backups.

Each migration copies the files it is about to change into
`$XDG_STATE_HOME/blox/backups/<stamp>/migrations/<id>/` before it runs, and
appends one ledger line per run. Rollback restores the most recent pre-image
for every applied migration of the generation being rolled back.
"""

from __future__ import annotations

import json
import os
import shutil
import time
from pathlib import Path
from typing import Any, Callable

from layout import Roots


class Migration:
    def __init__(self, identifier: str, description: str, run: Callable[[Roots, Path], dict[str, Any]], keep_on_rollback: bool = False):
        self.id = identifier
        self.description = description
        self.run = run
        # Data relocations stay after a version rollback: the originals
        # remain at the legacy path either way, and dropping the copies
        # would cut the user off from their own content. Transaction
        # failures still undo them because they are part of the install.
        self.keep_on_rollback = keep_on_rollback


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


def _data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))


def migrate_legacy_user_themes(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    """Copy $XDG_DATA_HOME/blox/themes to $XDG_DATA_HOME/blox-user/themes.

    Per-file conflict checks: an existing differing destination is left
    untouched and reported. Sources are recorded but NOT deleted here —
    the legacy directory often sits inside what becomes the package tree,
    so deletion happens only after the install commits
    (see installer.finalise_legacy_user_themes)."""
    legacy_root = _data_home() / "blox" / "themes"
    target_root = roots.data / "themes"
    sources: list[str] = []
    created: list[str] = []
    conflicts: list[str] = []
    if not legacy_root.is_dir():
        return {"moved": False}
    for source in sorted(legacy_root.rglob("*")):
        if not source.is_file():
            continue
        relative = source.relative_to(legacy_root)
        destination = target_root / relative
        if destination.exists():
            if sha256_file(destination) != sha256_file(source):
                conflicts.append(str(destination))
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        sources.append(str(source))
        created.append(str(destination))
    return {"moved": bool(created), "sources": sources, "created": created, "conflicts": conflicts}


def sha256_file(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(131072), b""):
            digest.update(chunk)
    return digest.hexdigest()


def migrate_active_theme_paths(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    """Repoint the active theme manifest at the relocated user-data root.

    The manifest's top-level `source` and every `target_sources[*].source`
    may reference the legacy directory that relocation empties. The file is
    modified in place with a pre-image so rollback can restore it."""
    import json as _json

    state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    manifest_path = state_home / "blox-theme" / "active.json"
    if not manifest_path.is_file():
        return {"moved": False}
    legacy_root = str(_data_home() / "blox" / "themes")
    new_root = str(roots.data / "themes")

    document = _json.loads(manifest_path.read_text(encoding="utf-8"))
    changed: list[str] = []

    def rewrite(node: Any) -> Any:
        if isinstance(node, dict):
            return {key: rewrite(value) for key, value in node.items()}
        if isinstance(node, list):
            return [rewrite(item) for item in node]
        if isinstance(node, str) and node.startswith(legacy_root + "/"):
            changed.append(node)
            return new_root + node[len(legacy_root):]
        return node

    rewritten = rewrite(document)
    if not changed:
        return {"moved": False}

    pre_image = backup_dir / "active.json"
    shutil.copy2(manifest_path, pre_image)
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(_json.dumps(rewritten, indent=2) + "\n", encoding="utf-8")
    shutil.copymode(str(pre_image), str(temporary))
    os.replace(str(temporary), str(manifest_path))
    return {
        "moved": True,
        "changed_count": len(changed),
        "detail": {"destination": str(manifest_path)},
        "pre_image_file": str(pre_image),
    }


MIGRATIONS: list[Migration] = [
    Migration("calendar-config-xdg", "Move the calendar allow-list into $XDG_CONFIG_HOME/blox.", migrate_calendar_config),
    Migration("shell-env-config", "Move the personal shell environment file into $XDG_CONFIG_HOME/blox.", migrate_shell_env),
    Migration("legacy-user-themes", "Relocate imported themes from $XDG_DATA_HOME/blox/themes into the separated user-data root.", migrate_legacy_user_themes, keep_on_rollback=True),
    Migration("active-theme-paths", "Repoint the active theme manifest at the relocated user-data root.", migrate_active_theme_paths, keep_on_rollback=True),
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
            # Migrations only create destinations that were absent before;
            # rollback therefore removes them instead of copying back.
            "existed": False,
            "result": "applied" if detail.get("moved") else "nothing-to-do",
            "created": detail.get("created", []),
            "pre_image_file": detail.get("pre_image_file"),
            "conflicts": detail.get("conflicts", []),
            "sources": detail.get("sources", []),
            "modified": bool(detail.get("pre_image_file")),
            "existed": bool(detail.get("pre_image_file")),
            "keep_on_rollback": migration.keep_on_rollback,
            "detail": detail.get("detail"),
        }
        _append_ledger(roots, entry)
        results.append(entry)
    return results


def _prune_empty_dirs(target_root: Path, stop_at: Path) -> None:
    """Remove directories that became empty up to (not including) stop_at."""
    current = target_root
    while current.is_dir() and current != stop_at and stop_at not in current.parents:
        try:
            next(current.iterdir())
            return
        except (OSError, StopIteration):
            pass
        try:
            current.rmdir()
        except OSError:
            return
        current = current.parent


def restore_ledger_after(roots: Roots, lines_before: int) -> int:
    """Undo every migration appended after `lines_before` and truncate.

    Used by the lifecycle transactions: a failed install or update must
    leave no migration effects behind."""
    entries = read_ledger(roots)
    if len(entries) <= lines_before:
        return 0
    undone = 0
    for entry in reversed(entries[lines_before:]):
        if entry.get("modified"):
            pre_image = entry.get("pre_image_file")
            destination = (entry.get("detail") or {}).get("destination")
            if pre_image and destination and Path(pre_image).is_file():
                shutil.copy2(pre_image, destination)
                undone += 1
            continue
        detail = entry.get("detail") or {}
        created_list = entry.get("created") or []
        single = detail.get("destination")
        victims = [Path(text) for text in created_list]
        if not victims and entry.get("result") == "applied" and single and not entry.get("existed", True):
            victims = [Path(single)]
        for victim in victims:
            if victim.is_symlink() or victim.exists():
                victim.unlink()
                undone += 1
        parent = victims[-1].parent if victims else None
        while parent and parent != roots.data and roots.data in parent.parents:
            try:
                next(parent.iterdir())
                break
            except (OSError, StopIteration):
                pass
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent
    kept = entries[:lines_before]
    with roots.migrations_ledger.open("w", encoding="utf-8") as handle:
        for entry in kept:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
    return undone


def restore_pre_images(roots: Roots) -> list[str]:
    """Undo applied migrations newest-first.

    Migrations only ever create destinations that did not exist before
    (existing files are left untouched and recorded as nothing-to-do), so
    restoring means removing what was created. Directory migrations record
    every created file in `created`; single-file migrations use the
    destination with `existed: false`.
    """
    restored: list[str] = []
    for entry in reversed(read_ledger(roots)):
        if entry.get("result") != "applied" or entry.get("keep_on_rollback"):
            continue
        if entry.get("modified"):
            pre_image = entry.get("pre_image_file")
            destination = (entry.get("detail") or {}).get("destination")
            if pre_image and destination and Path(pre_image).is_file():
                shutil.copy2(pre_image, destination)
                restored.append(destination)
            continue
        detail = entry.get("detail") or {}
        created_list = list(entry.get("created") or [])
        destination = detail.get("destination")
        if not created_list and destination and not entry.get("existed", True):
            created_list = [destination]
        for text in created_list:
            created_path = Path(text)
            if created_path.is_symlink() or created_path.exists():
                created_path.unlink()
                restored.append(text)
        if created_list:
            _prune_empty_dirs(Path(created_list[-1]).parent, roots.data)
            entry["result"] = "restored"
            _append_ledger(roots, {**entry})
    return restored
