#!/usr/bin/env python3
"""Local install health report for `bloxctl doctor`.

Read-only. Human output by default, typed JSON with --json. Every report is
redacted: home paths collapse to `~` and network identifiers never appear.
"""

from __future__ import annotations

import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPT_ROOT = Path(__file__).resolve().parent
PACKAGING_ROOT = SCRIPT_ROOT.parents[1] / "packaging"
sys.path.insert(0, str(PACKAGING_ROOT))

import layout  # noqa: E402
from install import check_dependencies, sha256  # noqa: E402

MAC_PATTERN = re.compile(r"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
SENSITIVE_KEYS = {"ssid", "psk", "password", "token", "account"}


def _redact_text(text: str, home: str) -> str:
    text = text.replace(home, "~")
    return MAC_PATTERN.sub("<mac>", text)


def redact(value: Any, home: str) -> Any:
    if isinstance(value, dict):
        return {
            key: ("<redacted>" if key.lower() in SENSITIVE_KEYS else redact(item, home))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item, home) for item in value]
    if isinstance(value, str):
        return _redact_text(value, home)
    return value


def _check(identifier: str, ok: bool, detail: Any = None, severity: str | None = None) -> dict[str, Any]:
    return {"id": identifier, "severity": severity or ("info" if ok else "error"), "ok": bool(ok), "detail": detail}


def _host_checks() -> list[dict[str, Any]]:
    checks = [_check("host-python", True, platform.python_version())]
    completed = subprocess.run(["quickshell", "--version"], capture_output=True, text=True, check=False)
    version = (completed.stdout or completed.stderr).strip().splitlines()[0] if completed.stdout or completed.stderr else ""
    checks.append(_check("host-quickshell", completed.returncode == 0, version or None))
    return checks


def _install_checks(roots: layout.Roots) -> list[dict[str, Any]]:
    manifest_path = roots.manifest
    if not manifest_path.is_file():
        return [_check("install-manifest", False, "Blox is not installed at this prefix")]
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except ValueError as error:
        return [_check("install-manifest", False, f"manifest is unreadable: {error}")]
    files = manifest.get("files", {})
    mismatched = [
        rel
        for rel, record in sorted(files.items())
        if not (roots.pkg_root / rel).is_file() or sha256(roots.pkg_root / rel) != record.get("sha256")
    ]
    return [
        _check("install-version", True, manifest.get("product_version")),
        _check(
            "install-files",
            not mismatched,
            {"checked": len(files), "mismatched": mismatched[:10], "mismatch_count": len(mismatched)},
            severity="info" if not mismatched else "warn",
        ),
    ]


def _path_checks(roots: layout.Roots) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    expected = {
        "paths-package-data": (roots.pkg_root, True),
        "paths-config": (roots.config, False),
        "paths-state": (roots.state, False),
        "paths-cache": (roots.cache, False),
    }
    for identifier, (path, required) in expected.items():
        exists = path.is_dir()
        checks.append(_check(identifier, exists or not required, str(path), severity="info" if exists else ("error" if required else "info")))
    return checks


def _unit_checks(roots: layout.Roots) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    for unit in ("quickshell.service", "gcal-update.service"):
        path = roots.systemd_user / unit
        checks.append(_check(f"unit-{unit.removesuffix('.service')}", path.is_file(), str(path)))
    completed = subprocess.run(["systemctl", "--user", "is-active", "quickshell.service"], capture_output=True, text=True, check=False)
    state = completed.stdout.strip() or "unknown"
    checks.append(_check("unit-quickshell-active", state == "active", state, severity="info"))
    return checks


def _defaults_check(roots: layout.Roots) -> list[dict[str, Any]]:
    data_dir = os.environ.get("BLOX_DATA_DIR")
    candidates = [Path(data_dir) / "defaults/v1.json" if data_dir else None, roots.pkg_root / "themes/defaults/v1.json"]
    for candidate in candidates:
        if candidate and candidate.is_file():
            try:
                document = json.loads(candidate.read_text(encoding="utf-8"))
            except ValueError as error:
                return [_check("defaults-document", False, f"{candidate}: {error}")]
            valid = document.get("schema_version") == 1 and document.get("defaults_version") == 1
            return [_check("defaults-document", valid, str(candidate))]
    return [_check("defaults-document", False, "no defaults document found")]


def _ipc_check() -> list[dict[str, Any]]:
    try:
        completed = subprocess.run(
            [str(SCRIPT_ROOT / "ipc.sh"), "blox", "status"],
            cwd=SCRIPT_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return [_check("ipc-status", False, "the Blox shell is not running", severity="warn")]
    if completed.returncode != 0:
        return [_check("ipc-status", False, "the Blox shell is not running", severity="warn")]
    try:
        payload = json.loads(completed.stdout.strip())
    except ValueError:
        return [_check("ipc-status", False, "invalid status data", severity="warn")]
    return [_check("ipc-status", payload.get("ok") is True, payload.get("code"), severity="info")]


def _migration_checks(roots: layout.Roots) -> list[dict[str, Any]]:
    from migrations import read_ledger

    entries = read_ledger(roots)
    tail = [
        {"time": entry.get("time"), "migration": entry.get("migration"), "result": entry.get("result")}
        for entry in entries[-5:]
    ]
    return [_check("migrations-ledger", True, {"entries": len(entries), "tail": tail})]


def _trust_check(roots: layout.Roots) -> list[dict[str, Any]]:
    trust_root = roots.data / "trust" / "themes"
    count = len(list(trust_root.glob("*.json"))) if trust_root.is_dir() else 0
    return [_check("trust-records", True, {"count": count}, severity="info")]


def collect() -> dict[str, Any]:
    roots = layout.resolve_roots()
    checks: list[dict[str, Any]] = []
    checks += _host_checks()
    checks += _install_checks(roots)
    checks += _path_checks(roots)
    checks += _unit_checks(roots)
    checks += check_dependencies()
    checks += _defaults_check(roots)
    checks += _ipc_check()
    checks += _migration_checks(roots)
    checks += _trust_check(roots)
    healthy = all(check["ok"] for check in checks if check["severity"] == "error")
    return {"version": 1, "healthy": healthy, "checks": checks}


def main(as_json: bool = False) -> int:
    home = str(Path.home())
    report = collect()
    report["redacted"] = True
    report = redact(report, home)
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    marks = {"info": "ok  ", "warn": "warn", "error": "FAIL"}
    for check in report["checks"]:
        line = f"[{marks[check['severity']]}] {check['id']}"
        if check["detail"] is not None:
            line += f": {json.dumps(check['detail'], sort_keys=True)}"
        print(line)
    print("healthy" if report["healthy"] else "unhealthy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main("--json" in sys.argv))
