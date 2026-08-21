"""Manifest-driven installer and lifecycle for the public product.

Rules (Phase 2 plan):

- unprivileged: every operation stays inside user-owned roots;
- idempotent: a repeated run performs no mutation;
- dry run predicts every real effect and writes nothing;
- conflicts are backed up, never silently overwritten;
- update keeps one previous generation; rollback restores it with pre-images;
- uninstall removes owned paths only and reports leftovers.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from layout import Roots

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_AREAS = ("shell", "themes", "bin", "packaging")
DATA_AREAS = ("applications",)  # desktop entries and icons, installed into $XDG_DATA_HOME
COPY_EXCLUDE = {"__pycache__", ".git"}
UNIT_TEMPLATES = ("quickshell.service.in", "gcal-update.service.in")
INSTALLED_BINS = ("bloxctl", "themectl", "dmenu")

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_UNAVAILABLE = 3
EXIT_CONFLICT = 5
EXIT_INVALID_DATA = 6


class LifecycleError(Exception):
    def __init__(self, code: str, message: str, data: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(131072), b""):
            digest.update(chunk)
    return digest.hexdigest()


def product_version(source_root: Path | None = None) -> str:
    root = source_root or REPO_ROOT
    version_file = root / "VERSION"
    if version_file.is_file():
        return version_file.read_text(encoding="utf-8").strip()
    raise LifecycleError("invalid-data", "No VERSION file in the source tree.")


def _iter_source_pairs(source_root: Path) -> list[tuple[Path, str]]:
    """Return (absolute file, repo-relative posix path) for every packaged file."""
    pairs: list[tuple[Path, str]] = []
    for area in SOURCE_AREAS:
        area_root = source_root / area
        for path in sorted(area_root.rglob("*")):
            if not path.is_file() or any(part in COPY_EXCLUDE for part in path.parts):
                continue
            pairs.append((path, path.relative_to(source_root).as_posix()))
    return pairs


def _iter_data_pairs(source_root: Path) -> list[tuple[Path, str]]:
    """Return (absolute file, data-home-relative posix path) for desktop entries."""
    pairs: list[tuple[Path, str]] = []
    for area in DATA_AREAS:
        area_root = source_root / area / ".local" / "share"
        if not area_root.is_dir():
            continue
        for path in sorted(area_root.rglob("*")):
            if not path.is_file() or any(part in COPY_EXCLUDE for part in path.parts):
                continue
            pairs.append((path, path.relative_to(area_root).as_posix()))
    return pairs


@dataclass
class Action:
    kind: str  # mkdir | copy | render-unit | link-bin
    target: Path
    detail: str = ""

    def as_json(self) -> dict[str, str]:
        return {"kind": self.kind, "target": str(self.target), "detail": self.detail}


@dataclass
class Conflict:
    target: Path
    reason: str

    def as_json(self) -> dict[str, str]:
        return {"target": str(self.target), "reason": self.reason}


@dataclass
class Plan:
    actions: list[Action] = field(default_factory=list)
    conflicts: list[Conflict] = field(default_factory=list)
    unchanged: int = 0

    def as_json(self) -> dict[str, Any]:
        return {
            "actions": [action.as_json() for action in self.actions],
            "conflicts": [conflict.as_json() for conflict in self.conflicts],
            "unchanged": self.unchanged,
        }


def _read_manifest(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def render_unit(template: str, roots: Roots, version: str, source_root: Path | None = None) -> str:
    root = source_root or REPO_ROOT
    text = (root / "packaging" / "units" / template).read_text(encoding="utf-8")
    for key, value in {
        "@PKG_ROOT@": str(roots.pkg_root),
        "@CONFIG_ROOT@": str(roots.config),
        "@VERSION@": version,
    }.items():
        text = text.replace(key, value)
    return text


def _bin_link_target(roots: Roots, name: str) -> str:
    return os.path.join("..", "share", "blox", "bin", name)


def build_plan(roots: Roots, source_root: Path | None = None) -> Plan:
    """Predict every effect of an install without touching the target."""
    root = source_root or REPO_ROOT
    plan = Plan()
    installed = _read_manifest(roots.manifest)

    for directory in (roots.pkg_root, roots.bins, roots.systemd_user):
        if not directory.is_dir():
            plan.actions.append(Action("mkdir", directory))

    for source, rel in _iter_source_pairs(root):
        target = roots.pkg_root / rel
        if not target.exists():
            plan.actions.append(Action("copy", target, rel))
            continue
        current = sha256(target)
        source_hash = sha256(source)
        # The recorded manifest arbitrates ownership: a file that matches
        # neither the manifest nor the incoming source is foreign, even when
        # the installer runs from the installed tree itself.
        recorded = installed.get("files", {}).get(rel, {}).get("sha256") if installed else None
        if current == source_hash and (recorded is None or recorded == current):
            plan.unchanged += 1
        elif recorded is not None and recorded == current:
            plan.actions.append(Action("copy", target, rel))
        else:
            plan.conflicts.append(Conflict(target, "existing file is not owned by the recorded manifest"))
            # Planned as well so --force backs the foreign file up and replaces it.
            plan.actions.append(Action("copy", target, rel))

    data_home = roots.data.parent
    for source, rel in _iter_data_pairs(root):
        target = data_home / rel
        if not target.exists():
            plan.actions.append(Action("copy-data", target, rel))
            continue
        current = sha256(target)
        recorded = installed.get("data_files", {}).get(rel, {}).get("sha256") if installed else None
        if current == sha256(source) and (recorded is None or recorded == current):
            plan.unchanged += 1
        elif recorded is not None and recorded == current:
            plan.actions.append(Action("copy-data", target, rel))
        else:
            plan.conflicts.append(Conflict(target, "existing file is not owned by the recorded manifest"))
            plan.actions.append(Action("copy-data", target, rel))

    version = product_version(root)
    for template in UNIT_TEMPLATES:
        target = roots.systemd_user / template.removesuffix(".in")
        rendered = render_unit(template, roots, version, root)
        if not target.exists() or target.read_text(encoding="utf-8") != rendered:
            plan.actions.append(Action("render-unit", target, template))
        else:
            plan.unchanged += 1

    for name in INSTALLED_BINS:
        link = roots.bins / name
        expected = _bin_link_target(roots, name)
        if link.is_symlink() and os.readlink(link) == expected:
            plan.unchanged += 1
        elif link.is_symlink():
            plan.actions.append(Action("link-bin", link, name))
        elif link.exists():
            plan.conflicts.append(Conflict(link, "existing program is not a Blox link"))
        else:
            plan.actions.append(Action("link-bin", link, name))
    return plan


def _backup_conflict(roots: Roots, target: Path, stamp: str) -> Path:
    if target.is_relative_to(roots.pkg_root):
        destination = roots.backups / stamp / "pkg" / target.relative_to(roots.pkg_root)
    else:
        destination = roots.backups / stamp / "misc" / target.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target, destination)
    entry = {"time": stamp, "original": str(target), "backup": str(destination), "sha256": sha256(target)}
    with (roots.backups / "ledger.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
    return destination


def _require_external_source(roots: Roots, source_root: Path | None) -> Path:
    """Install and update need a source tree outside the installed root."""
    root = source_root or REPO_ROOT
    try:
        same = root.samefile(roots.pkg_root)
    except OSError:
        same = False
    if same:
        raise LifecycleError(
            "unavailable",
            "No source tree is available from the installed CLI. Run lifecycle install from a checkout or release artefact.",
        )
    return root


def install(roots: Roots, dry_run: bool = False, force: bool = False, source_root: Path | None = None) -> dict[str, Any]:
    root = _require_external_source(roots, source_root)
    version = product_version(root)
    plan = build_plan(roots, root)
    report: dict[str, Any] = {"version": version, "dry_run": dry_run, "plan": plan.as_json()}
    if dry_run:
        return report
    if plan.conflicts and not force:
        raise LifecycleError(
            "conflict",
            "Existing files are not owned by Blox. Review the report, then rerun with --force to back them up.",
            {"conflicts": [conflict.as_json() for conflict in plan.conflicts]},
        )

    stamp = time.strftime("%Y%m%dT%H%M%S")
    backed_up: list[str] = []
    for action in plan.actions:
        if action.kind == "mkdir":
            action.target.mkdir(parents=True, exist_ok=True)
        elif action.kind == "copy":
            source = root / action.detail
            action.target.parent.mkdir(parents=True, exist_ok=True)
            if action.target.exists():
                _backup_conflict(roots, action.target, stamp)
                backed_up.append(str(action.target))
                action.target.unlink()
            shutil.copy2(source, action.target)
        elif action.kind == "copy-data":
            source = root / "applications" / ".local" / "share" / action.detail
            action.target.parent.mkdir(parents=True, exist_ok=True)
            if action.target.exists():
                _backup_conflict(roots, action.target, stamp)
                backed_up.append(str(action.target))
                action.target.unlink()
            shutil.copy2(source, action.target)
        elif action.kind == "render-unit":
            action.target.parent.mkdir(parents=True, exist_ok=True)
            if action.target.exists():
                _backup_conflict(roots, action.target, stamp)
                backed_up.append(str(action.target))
            action.target.write_text(render_unit(action.detail, roots, version, root), encoding="utf-8")
            os.chmod(action.target, 0o644)
        elif action.kind == "link-bin":
            action.target.parent.mkdir(parents=True, exist_ok=True)
            if action.target.is_symlink() or action.target.exists():
                _backup_conflict(roots, action.target, stamp)
                backed_up.append(str(action.target))
                action.target.unlink()
            os.symlink(_bin_link_target(roots, action.detail), action.target)

    # The version file is package metadata: the installed CLI reads it for
    # update and rollback decisions, so it ships inside the package root.
    version_source = root / "VERSION"
    version_target = roots.pkg_root / "VERSION"
    if version_source.is_file() and not (version_target.exists() and version_source.samefile(version_target)):
        shutil.copy2(version_source, version_target)

    files = {rel: {"sha256": sha256(target)} for target, rel in _iter_source_pairs(root)}
    if (roots.pkg_root / "VERSION").is_file():
        files["VERSION"] = {"sha256": sha256(roots.pkg_root / "VERSION")}
    data_home = roots.data.parent
    data_files = {rel: {"sha256": sha256(data_home / rel)} for _, rel in _iter_data_pairs(root)}
    manifest = {
        "manifest_version": 1,
        "product_version": version,
        "prefix": str(roots.prefix),
        "files": files,
        "data_files": data_files,
        "units": [template.removesuffix(".in") for template in UNIT_TEMPLATES],
        "bins": list(INSTALLED_BINS),
    }
    roots.manifest.parent.mkdir(parents=True, exist_ok=True)
    roots.manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    report["backed_up"] = backed_up
    report["installed"] = True
    return report


def uninstall(roots: Roots, purge: bool = False, dry_run: bool = False) -> dict[str, Any]:
    installed = _read_manifest(roots.manifest)
    if not installed:
        raise LifecycleError("unavailable", "Blox is not installed at this prefix.")

    planned: list[str] = []
    for rel in sorted(installed.get("files", {})):
        planned.append(str(roots.pkg_root / rel))
    for name in installed.get("bins", []):
        planned.append(str(roots.bins / name))
    for unit in installed.get("units", []):
        planned.append(str(roots.systemd_user / unit))
    for rel in sorted(installed.get("data_files", {})):
        planned.append(str(roots.data.parent / rel))
    planned.extend([str(roots.previous_pkg_root), str(roots.pkg_root)])
    if purge:
        planned.extend([str(roots.config), str(roots.data), str(roots.state), str(roots.cache)])

    removed: list[str] = []
    leftovers: list[str] = []
    if dry_run:
        return {"dry_run": True, "removed": planned, "leftovers": [], "purged": purge}

    for text in planned:
        path = Path(text)
        if path.is_symlink() or path.is_file():
            path.unlink()
            removed.append(text)
        elif path.is_dir():
            shutil.rmtree(path)
            removed.append(text)

    for name in installed.get("bins", []):
        link = roots.bins / name
        if link.exists() and not link.is_symlink():
            leftovers.append(str(link))
    if not purge:
        for root in (roots.config, roots.data, roots.state):
            if root.is_dir() and any(root.iterdir()):
                leftovers.append(str(root))
    return {"dry_run": False, "removed": removed, "leftovers": leftovers, "purged": purge}


def update(roots: Roots, dry_run: bool = False, source_root: Path | None = None) -> dict[str, Any]:
    from migrations import run_migrations

    source_root = _require_external_source(roots, source_root)
    installed = _read_manifest(roots.manifest)
    if not installed:
        raise LifecycleError("unavailable", "Blox is not installed; run lifecycle install first.")
    version = product_version(source_root)
    current = str(installed.get("product_version"))
    if version == current:
        return {"updated": False, "version": version, "reason": "already at this version"}
    if dry_run:
        return {"updated": True, "from": current, "to": version, "dry_run": True}

    if roots.previous_pkg_root.exists():
        shutil.rmtree(roots.previous_pkg_root)
    shutil.move(str(roots.pkg_root), str(roots.previous_pkg_root))
    try:
        result = install(roots, source_root=source_root)
    except Exception:
        # Restore the previous generation without nesting it inside a
        # partially written tree.
        if roots.previous_pkg_root.exists():
            if roots.pkg_root.exists():
                shutil.rmtree(roots.pkg_root)
            shutil.move(str(roots.previous_pkg_root), str(roots.pkg_root))
        raise
    migration_result = run_migrations(roots, from_version=current, to_version=version)
    _append_generation(roots, current, version, "applied")
    result.update({"updated": True, "from": current, "to": version, "migrations": migration_result})
    return result


def rollback(roots: Roots, dry_run: bool = False) -> dict[str, Any]:
    from migrations import restore_pre_images

    if not roots.previous_pkg_root.exists() or not roots.pkg_root.exists():
        raise LifecycleError("unavailable", "No previous generation is available to roll back to.")
    if dry_run:
        return {"rolled_back": True, "dry_run": True}
    restored = restore_pre_images(roots)
    shutil.rmtree(roots.pkg_root)
    shutil.move(str(roots.previous_pkg_root), str(roots.pkg_root))
    _append_generation(roots, "current", "previous", "rolled-back")
    return {"rolled_back": True, "pre_images_restored": restored}


def _append_generation(roots: Roots, from_version: str, to_version: str, result: str) -> None:
    ledger: list[dict[str, Any]] = []
    if roots.generations.is_file():
        try:
            ledger = json.loads(roots.generations.read_text(encoding="utf-8"))
        except ValueError:
            ledger = []
    ledger.append({"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "from": from_version, "to": to_version, "result": result})
    roots.generations.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")


REQUIRED_COMMANDS = ("python3", "quickshell", "jq")


def check_dependencies() -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []

    def have(command: str) -> bool:
        return shutil.which(command) is not None

    for command in REQUIRED_COMMANDS:
        present = have(command)
        checks.append({
            "id": f"command-{command}",
            "severity": "info" if present else "error",
            "ok": present,
            "detail": None if present else "required command is missing",
        })
    font_ok = False
    fc_list = shutil.which("fc-list")
    if fc_list:
        completed = subprocess.run([fc_list, ":"], capture_output=True, text=True, check=False)
        font_ok = completed.returncode == 0 and "nerd font propo" in completed.stdout.lower()
    checks.append({
        "id": "font-nerd-propo",
        "severity": "info" if font_ok else "warn",
        "ok": font_ok,
        "detail": None if font_ok else "no Nerd Font Propo family found; bar glyphs will fall back",
    })
    return checks
