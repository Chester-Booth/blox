"""Forward-only user-data migrations with pre-image backups.

Each migration copies the files it is about to change into
`$XDG_STATE_HOME/blox/backups/<stamp>/migrations/<id>/` before it runs, and
appends one ledger line per run. Rollback restores the most recent pre-image
for every applied migration of the generation being rolled back. Pre-release
paths are migrated once and are not kept as compatibility interfaces.
"""

from __future__ import annotations

import json
import os
import shutil
import time
import uuid
from pathlib import Path
from typing import Any, Callable

from layout import Roots


class Migration:
    def __init__(self, identifier: str, description: str, run: Callable[[Roots, Path], dict[str, Any]], keep_on_rollback: bool = False):
        self.id = identifier
        self.description = description
        self.run = run
        # Data relocations may stay after a package rollback because they
        # move user data. Transaction failures always undo them because they
        # are part of the install.
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


def migrate_legacy_helium_desktop_entry(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    """Remove the old Blox-owned Helium desktop ID after the rename.

    A user-owned Helium entry must stay untouched. The old Blox entry is
    identified by its wrapper command and receives a pre-image so rollback
    and failed installs can restore it.
    """
    legacy = _data_home() / "applications" / "helium-browser.desktop"
    if legacy.is_symlink() or not legacy.is_file():
        return {"moved": False}
    try:
        text = legacy.read_text(encoding="utf-8")
    except OSError:
        return {"moved": False}
    if "Name=Helium Browser" not in text or "Exec=blox-helium-browser %U" not in text:
        return {"moved": False}

    pre_image = backup_dir / legacy.name
    shutil.copy2(legacy, pre_image)
    legacy.unlink()
    return {
        "moved": True,
        "pre_image_file": str(pre_image),
        "detail": {"destination": str(legacy), "action": "removed"},
    }


def _data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))


def migrate_legacy_user_themes(roots: Roots, backup_dir: Path, package_rels: set[str] | None = None) -> dict[str, Any]:
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
    package_owned = 0
    if not legacy_root.is_dir():
        return {"moved": False}
    for source in sorted(legacy_root.rglob("*")):
        if not source.is_file():
            continue
        relative = source.relative_to(legacy_root)
        # When the prefix is the user data home, the package tree itself
        # lives inside the legacy directory. Files the incoming install
        # owns are package content, not user data: skip them entirely so
        # they are neither duplicated into the user library nor deleted
        # from the package by the post-commit cleanup.
        if package_rels and f"themes/{relative.as_posix()}" in package_rels:
            package_owned += 1
            continue
        destination = target_root / relative
        if destination.exists():
            if sha256_file(destination) != sha256_file(source):
                conflicts.append(str(destination))
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        sources.append(str(source))
        created.append(str(destination))
    return {"moved": bool(created), "sources": sources, "created": created,
            "conflicts": conflicts, "package_owned": package_owned}


def sha256_file(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(131072), b""):
            digest.update(chunk)
    return digest.hexdigest()


def migrate_active_theme_paths(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    """Repoint the active theme manifest at the relocated user-data root.

    active.json is a symlink (active.json -> current/manifest.json,
    current -> generations/<id>). The migration resolves it, validates the
    target is a regular file, and atomically updates the generation
    manifest in its own directory; both symlinks stay byte-for-byte.
    Top-level `source` and every `target_sources[*].source` referencing the
    legacy directory are rewritten under a pre-image for rollback."""
    import json as _json

    manifest_path = roots.theme_state / "active.json"
    if not manifest_path.is_symlink():
        # Real topology: active.json is a symlink through current into the
        # generation tree. Refuse anything else rather than replace it.
        return {"moved": False}
    target = manifest_path.resolve(strict=True)
    if not target.is_file():
        return {"moved": False}
    legacy_root = str(_data_home() / "blox" / "themes")
    new_root = str(roots.data / "themes")

    original_bytes = target.read_bytes()
    document = _json.loads(original_bytes.decode("utf-8"))
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

    rewritten = dict(document)
    if isinstance(document.get("source"), str):
        rewritten["source"] = rewrite(document["source"])
    target_sources = document.get("target_sources")
    if isinstance(target_sources, dict):
        rewritten_targets = dict(target_sources)
        for target_name, value in target_sources.items():
            if isinstance(value, dict) and isinstance(value.get("source"), str):
                rewritten_value = dict(value)
                rewritten_value["source"] = rewrite(value["source"])
                rewritten_targets[target_name] = rewritten_value
        rewritten["target_sources"] = rewritten_targets
    if not changed:
        return {"moved": False}

    pre_image = backup_dir / "active.json"
    pre_image.write_bytes(original_bytes)
    # Atomically update the generation manifest in its own directory; the
    # active.json and current symlinks are never touched.
    temporary = target.parent / f".{target.name}.tmp-{os.getpid()}"
    temporary.write_text(_json.dumps(rewritten, indent=2) + "\n", encoding="utf-8")
    shutil.copymode(str(target), str(temporary))
    os.replace(str(temporary), str(target))
    return {
        "moved": True,
        "changed_count": len(changed),
        "detail": {"destination": str(target)},
        "pre_image_file": str(pre_image),
    }


def _state_tree_paths(root: Path) -> list[Path]:
    """Return a state tree's entries without following directory links."""
    return sorted(root.rglob("*"))


def _validate_state_tree(root: Path) -> None:
    """Reject state entries that could make a migration leave its root."""
    if not root.is_dir() or root.is_symlink():
        raise RuntimeError(f"theme state root is not a real directory: {root}")
    resolved_root = root.resolve()
    for path in _state_tree_paths(root):
        if not path.is_symlink():
            if not path.is_file() and not path.is_dir():
                raise RuntimeError(f"unsupported entry in theme state: {path}")
            continue
        link = os.readlink(path)
        if os.path.isabs(link):
            raise RuntimeError(f"absolute link is not allowed in theme state: {path}")
        target = (path.parent / link).resolve()
        try:
            target.relative_to(resolved_root)
        except ValueError as error:
            raise RuntimeError(f"theme state link escapes its root: {path}") from error
        if not target.exists():
            raise RuntimeError(f"broken link in theme state: {path}")


def _remove_tree(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def migrate_theme_state_root(roots: Roots, backup_dir: Path) -> dict[str, Any]:
    """Move generated theme state into the lifecycle-owned state tree.

    The old root is a pre-release layout. A complete copy of it is retained
    in the migration backup so a failed lifecycle transaction can restore the
    exact old topology, but a successful migration leaves no old path behind.
    """
    legacy = roots.state.parent / "blox-theme"
    canonical = roots.theme_state
    if legacy.is_symlink():
        raise RuntimeError(f"refusing unsupported pre-release theme-state link: {legacy}")
    if not legacy.exists():
        return {"moved": False, "detail": {"source": "not-found"}}
    if not legacy.is_dir():
        raise RuntimeError(f"legacy theme state is not a directory: {legacy}")
    if canonical.is_symlink() or canonical.exists():
        raise RuntimeError(f"refusing to replace existing canonical theme state: {canonical}")

    _validate_state_tree(legacy)
    backup_dir.mkdir(parents=True, exist_ok=True)
    pre_image = backup_dir / "legacy-theme-state"
    stage = canonical.parent / f".theme-state-stage-{uuid.uuid4().hex}"
    moved_original = backup_dir / "legacy-theme-state-original"
    try:
        shutil.copytree(legacy, pre_image, symlinks=True)
        shutil.copytree(legacy, stage, symlinks=True)
        _validate_state_tree(stage)
        os.replace(stage, canonical)
        os.replace(legacy, moved_original)
    except BaseException:
        if stage.exists() or stage.is_symlink():
            _remove_tree(stage)
        if legacy.is_symlink():
            legacy.unlink()
        if moved_original.exists() or moved_original.is_symlink():
            os.replace(moved_original, legacy)
        if canonical.exists() or canonical.is_symlink():
            _remove_tree(canonical)
        raise
    return {
        "moved": True,
        "detail": {
            "legacy_root": str(legacy),
            "destination": str(canonical),
        },
        "pre_image_tree": str(pre_image),
        "moved_original": str(moved_original),
    }


MIGRATIONS: list[Migration] = [
    Migration("calendar-config-xdg", "Move the calendar allow-list into $XDG_CONFIG_HOME/blox.", migrate_calendar_config),
    Migration("shell-env-config", "Move the personal shell environment file into $XDG_CONFIG_HOME/blox.", migrate_shell_env),
    Migration("helium-desktop-id", "Remove the old Blox-owned Helium desktop entry after its ID rename.", migrate_legacy_helium_desktop_entry),
    Migration("theme-state-root", "Move generated theme state under $XDG_STATE_HOME/blox/theme.", migrate_theme_state_root, keep_on_rollback=True),
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


def run_migrations(roots: Roots, from_version: str, to_version: str, package_rels: set[str] | None = None) -> list[dict[str, Any]]:
    stamp = time.strftime("%Y%m%dT%H%M%S")
    results: list[dict[str, Any]] = []
    for migration in MIGRATIONS:
        backup_dir = roots.backups / stamp / "migrations" / migration.id
        backup_dir.mkdir(parents=True, exist_ok=True)
        detail = migration.run(roots, backup_dir) if migration.id != "legacy-user-themes" else migration.run(roots, backup_dir, package_rels=package_rels)
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
            "pre_image_tree": detail.get("pre_image_tree"),
            "moved_original": detail.get("moved_original"),
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


def _restore_theme_state_root(entry: dict[str, Any]) -> None:
    """Restore the old state directory after a failed transaction."""
    detail = entry.get("detail") or {}
    legacy = Path(detail["legacy_root"])
    canonical = Path(detail["destination"])
    pre_image = Path(entry["pre_image_tree"])
    if legacy.is_symlink() or legacy.exists():
        _remove_tree(legacy)
    if canonical.is_symlink() or canonical.exists():
        _remove_tree(canonical)
    shutil.copytree(pre_image, legacy, symlinks=True)
    backup_root = Path(entry.get("pre_image", ""))
    if backup_root.is_dir():
        shutil.rmtree(backup_root)


def restore_ledger_after(roots: Roots, lines_before: int) -> int:
    """Undo every migration appended after `lines_before` and truncate.

    Used by the lifecycle transactions: a failed install or update must
    leave no migration effects behind."""
    entries = read_ledger(roots)
    if len(entries) <= lines_before:
        return 0
    undone = 0
    for entry in reversed(entries[lines_before:]):
        if entry.get("migration") == "theme-state-root" and entry.get("pre_image_tree"):
            _restore_theme_state_root(entry)
            undone += 1
            continue
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
    if kept:
        with roots.migrations_ledger.open("w", encoding="utf-8") as handle:
            for entry in kept:
                handle.write(json.dumps(entry, sort_keys=True) + "\n")
    else:
        roots.migrations_ledger.unlink(missing_ok=True)
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
