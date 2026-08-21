#!/usr/bin/env python3
"""Small public CLI adapter for the supervised Blox shell action owner."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_ROOT = Path(__file__).resolve().parent
IPC = SCRIPT_ROOT / "ipc.sh"
PACKAGING_ROOT = SCRIPT_ROOT.parents[1] / "packaging"
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_UNAVAILABLE = 3
EXIT_DENIED = 4
EXIT_CONFLICT = 5
EXIT_INVALID_DATA = 6
EXIT_INTERNAL = 1


def result(ok: bool, code: str, message: str = "", data: Any = None) -> dict[str, Any]:
    return {
        "version": 1,
        "ok": ok,
        "code": code,
        "message": message,
        "data": data,
    }


def exit_code(action: dict[str, Any]) -> int:
    if action.get("ok") is True:
        return EXIT_OK
    return {
        "permission-denied": EXIT_DENIED,
        "conflict": EXIT_CONFLICT,
        "invalid-data": EXIT_INVALID_DATA,
        "unavailable": EXIT_UNAVAILABLE,
    }.get(action.get("code"), EXIT_INTERNAL)


def call_owner() -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [str(IPC), "blox", "status"],
            cwd=SCRIPT_ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return result(False, "unavailable", "The Blox shell is not running.")

    if completed.returncode != 0:
        return result(False, "unavailable", "The Blox shell is not running.")

    try:
        action = json.loads(completed.stdout.strip())
    except json.JSONDecodeError:
        return result(False, "invalid-data", "The Blox shell returned invalid status data.")

    if not isinstance(action, dict):
        return result(False, "invalid-data", "The Blox shell returned a non-object status result.")
    required = {"version", "ok", "code", "message", "data"}
    if set(action) != required or action["version"] != 1 or not isinstance(action["ok"], bool):
        return result(False, "invalid-data", "The Blox shell returned an invalid action result.")
    return action


def run_lifecycle(command: str, options: dict[str, Any]) -> dict[str, Any]:
    if str(PACKAGING_ROOT) not in sys.path:
        sys.path.insert(0, str(PACKAGING_ROOT))
    import layout
    import install as installer

    roots = layout.resolve_roots()
    if options.get("prefix"):
        from dataclasses import replace

        expanded = Path(options["prefix"]).expanduser()
        roots = replace(roots, prefix=expanded, pkg_root=expanded / "share" / "blox")
    try:
        if command == "install":
            report = installer.install(roots, dry_run=options["dry_run"], force=options["force"])
        elif command == "update":
            report = installer.update(roots, dry_run=options["dry_run"])
        elif command == "rollback":
            report = installer.rollback(roots, dry_run=options["dry_run"])
        elif command == "uninstall":
            report = installer.uninstall(roots, purge=options["purge"], dry_run=options["dry_run"])
        else:
            return result(False, "usage", f"Unknown lifecycle command: {command}")
    except installer.LifecycleError as error:
        return result(False, error.code, error.message, error.data)
    except (OSError, ValueError) as error:
        return result(False, "internal", f"Lifecycle operation failed: {error}")
    return result(True, "ok", "", report)


def run_doctor(as_json: bool) -> tuple[int, dict[str, Any], bool]:
    import sys as _sys

    if str(SCRIPT_ROOT) not in _sys.path:
        _sys.path.insert(0, str(SCRIPT_ROOT))
    import doctor

    try:
        report = doctor.collect()
    except (OSError, ValueError) as error:
        return EXIT_INTERNAL, result(False, "internal", f"Doctor failed: {error}"), False
    from doctor import redact

    report["redacted"] = True
    report = redact(report, str(Path.home()))
    if not as_json:
        marks = {"info": "ok  ", "warn": "warn", "error": "FAIL"}
        for check in report["checks"]:
            line = f"[{marks[check['severity']]}] {check['id']}"
            if check["detail"] is not None:
                line += f": {json.dumps(check['detail'], sort_keys=True)}"
            print(line)
        print("healthy" if report["healthy"] else "unhealthy")
        return EXIT_OK, result(True, "ok"), True
    return EXIT_OK, result(True, "ok", "", report), False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bloxctl")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", dest="as_json")
    common.add_argument("--prefix")
    groups = parser.add_subparsers(dest="group", required=True)

    status = groups.add_parser("status", help="typed status through the running shell")
    status.add_argument("--json", action="store_true", dest="as_json")

    doctor = groups.add_parser("doctor", help="local install health report")
    doctor.add_argument("--json", action="store_true", dest="as_json")

    for name in ("settings", "theme"):
        reserved = groups.add_parser(name)
        reserved.add_argument("--json", action="store_true", dest="as_json")

    lifecycle = groups.add_parser("lifecycle", help="install, update, rollback and uninstall")
    commands = lifecycle.add_subparsers(dest="lifecycle_command", required=True)

    install_parser = commands.add_parser("install", parents=[common])
    install_parser.add_argument("--dry-run", action="store_true")
    install_parser.add_argument("--force", action="store_true")

    update_parser = commands.add_parser("update", parents=[common])
    update_parser.add_argument("--dry-run", action="store_true")

    rollback_parser = commands.add_parser("rollback", parents=[common])
    rollback_parser.add_argument("--dry-run", action="store_true")

    uninstall_parser = commands.add_parser("uninstall", parents=[common])
    uninstall_parser.add_argument("--dry-run", action="store_true")
    uninstall_parser.add_argument("--purge", action="store_true")
    return parser


def run(argv: list[str]) -> tuple[int, dict[str, Any], bool, bool]:
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as error:
        return int(error.code), result(False, "usage", "Use: bloxctl {status|doctor|settings|theme|lifecycle} --help."), "--json" in argv, False

    as_json = getattr(args, "as_json", False)

    if args.group == "status":
        action = call_owner()
        return exit_code(action), action, as_json, False

    if args.group == "doctor":
        code, action, printed = run_doctor(as_json)
        return code, action, as_json, printed

    if args.group in ("settings", "theme"):
        return EXIT_UNAVAILABLE, result(False, "unavailable", f"The {args.group} commands belong to a later phase."), as_json, False

    if args.group == "lifecycle":
        options = {
            "dry_run": getattr(args, "dry_run", False),
            "force": getattr(args, "force", False),
            "purge": getattr(args, "purge", False),
            "prefix": getattr(args, "prefix", None),
        }
        action = run_lifecycle(args.lifecycle_command, options)
        return exit_code(action), action, as_json, False

    return EXIT_USAGE, result(False, "usage", "Use: bloxctl status [--json]."), as_json, False


def main(argv: list[str] | None = None) -> int:
    code, action, as_json, printed = run(sys.argv[1:] if argv is None else argv)
    if printed:
        return code
    if as_json:
        print(json.dumps(action, separators=(",", ":"), sort_keys=True))
    elif action["ok"]:
        print(json.dumps(action["data"], indent=2, sort_keys=True))
    else:
        print(action["message"], file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
