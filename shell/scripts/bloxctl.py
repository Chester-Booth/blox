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
THEME_LIBRARY = SCRIPT_ROOT.parents[1] / "themes" / "lib"


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


def _theme_modules():
    """Load the installed theme library without depending on a checkout."""
    if not THEME_LIBRARY.is_dir():
        raise ImportError(f"installed theme library is missing: {THEME_LIBRARY}")
    if str(THEME_LIBRARY) not in sys.path:
        sys.path.insert(0, str(THEME_LIBRARY))
    from blox_theme import core, runtime

    return core, runtime


def _redact_theme_paths(value: Any) -> Any:
    """Keep public theme output useful without leaking the home directory."""
    if isinstance(value, dict):
        return {key: _redact_theme_paths(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_redact_theme_paths(item) for item in value]
    if isinstance(value, str):
        home = str(Path.home())
        return value.replace(home, "~") if home and home != "/" else value
    return value


def _theme_error(command: str, code: str, message: str, data: Any = None) -> dict[str, Any]:
    return result(False, code, _redact_theme_paths(message), _redact_theme_paths(data))


def _theme_load(command: str, reference: str, core):
    try:
        path, resolved = core.load_theme(reference)
        source = core.load_json(path)
        if not isinstance(source, dict):
            raise ValueError("theme source must be a JSON object")
        checked = core.validate_theme(resolved, check_dependencies=False, source_path=path)
    except FileNotFoundError as error:
        return None, None, None, _theme_error(command, "invalid-data", str(error))
    except (OSError, json.JSONDecodeError, ValueError, TypeError) as error:
        return None, None, None, _theme_error(command, "invalid-data", str(error))
    if checked.errors:
        return None, None, None, _theme_error(command, "invalid-data", "; ".join(checked.errors))
    return path, source, resolved, None


def _theme_origin(path, theme, core) -> dict[str, Any]:
    if core.is_builtin_theme_path(path):
        return {"kind": "builtin", "theme_id": theme["id"], "fallback": False}
    return {"kind": "builtin", "theme_id": core.DEFAULT_THEME_ID, "fallback": True}


def _dependency_failure(messages: list[str]) -> bool:
    markers = ("not installed", "required command", "dependency", "does not exist")
    return any(marker in message.casefold() for message in messages for marker in markers)


def _public_apply(command: str, path, theme, core, runtime, extra_warnings: list[str] | None = None):
    try:
        selected = runtime.configured_targets(theme)
    except runtime.RuntimeFailure as error:
        return _theme_error(command, "invalid-data", str(error))
    if not selected:
        return _theme_error(command, "invalid-data", "theme enables no implemented runtime targets")
    checked = core.validate_theme(
        theme,
        check_dependencies=True,
        targets=set(selected),
        source_path=path,
        dependency_gate=True,
    )
    if checked.errors:
        code = "unavailable" if _dependency_failure(checked.errors) else "invalid-data"
        return _theme_error(command, code, "; ".join(checked.errors), {"theme_id": theme["id"], "errors": checked.errors})
    try:
        manifest, warnings = runtime.apply_theme(
            path,
            theme,
            runtime.TARGET_NAMES,
            authoritative_targets=True,
        )
    except runtime.LockContended as error:
        return _theme_error(command, "conflict", str(error))
    except PermissionError as error:
        return _theme_error(command, "permission-denied", str(error))
    except (OSError, runtime.RuntimeFailure, TypeError, ValueError) as error:
        return _theme_error(command, "internal", str(error))
    all_warnings = list(extra_warnings or []) + checked.warnings + warnings
    return result(
        True,
        "ok",
        "",
        _redact_theme_paths({
            "generation": manifest["generation_id"],
            "theme_id": manifest["theme_id"],
            "active_targets": manifest["enabled_targets"],
            "warnings": all_warnings,
        }),
    )


def run_theme(args) -> tuple[int, dict[str, Any]]:
    try:
        core, runtime = _theme_modules()
    except (ImportError, OSError) as error:
        return EXIT_UNAVAILABLE, _theme_error("theme", "unavailable", str(error))

    command = args.theme_command
    if command == "list":
        try:
            entries = core.list_themes()
        except (OSError, ValueError, TypeError) as error:
            return EXIT_INTERNAL, _theme_error(command, "internal", str(error))
        invalid = [entry for entry in entries if entry.get("invalid")]
        data = {
            "themes": entries,
            "invalid": invalid,
        }
        if invalid:
            message = f"{len(invalid)} theme source(s) are invalid"
            return EXIT_INVALID_DATA, _theme_error(command, "invalid-data", message, data)
        return EXIT_OK, result(True, "ok", "", _redact_theme_paths(data))

    if command in ("show", "preview", "apply"):
        path, source, theme, failure = _theme_load(command, args.theme, core)
        if failure:
            return EXIT_INVALID_DATA, failure
        assert path is not None and source is not None and theme is not None

        if command == "show":
            data = {
                "id": theme["id"],
                "path": str(path),
                "source_kind": "builtin" if core.is_builtin_theme_path(path) else "user",
                "origin": _theme_origin(path, theme, core),
                "source": source,
                "resolved": theme,
                "inherited_paths": core.theme_inherited_paths(source, theme),
            }
            return EXIT_OK, result(True, "ok", "", _redact_theme_paths(data))

        if command == "preview":
            try:
                files, warnings = core.render_theme(theme, path)
                changes = core.rendered_diff(files)
            except (OSError, KeyError, TypeError, ValueError) as error:
                return EXIT_INTERNAL, _theme_error(command, "internal", f"theme preview failed: {error}")
            data = {
                "theme_id": theme["id"],
                "source": str(path),
                "resolved": theme,
                "inherited_paths": core.theme_inherited_paths(source, theme),
                "state_directory": str(core.state_dir()),
                "changes": changes,
                "rendered_files": list(files),
            }
            return EXIT_OK, result(True, "ok", "", _redact_theme_paths({**data, "warnings": warnings}))

        return _theme_exit(_public_apply(command, path, theme, core, runtime))

    if command == "reset":
        try:
            record = runtime.current_generation()
        except runtime.RuntimeFailure as error:
            return EXIT_INVALID_DATA, _theme_error(command, "invalid-data", str(error))
        if not record:
            return EXIT_UNAVAILABLE, _theme_error(command, "unavailable", "no active theme generation")
        manifest = record[1]
        origin = manifest.get("origin")
        warnings: list[str] = []
        origin_id = origin.get("theme_id") if isinstance(origin, dict) else None
        if not isinstance(origin_id, str) or not origin_id:
            origin_id = core.DEFAULT_THEME_ID
            warnings.append(f"active generation has no origin metadata; reset used built-in {origin_id}")
        path, _source, theme, failure = _theme_load(command, origin_id, core)
        if failure:
            return EXIT_INVALID_DATA, failure
        assert path is not None and theme is not None
        action = _public_apply(command, path, theme, core, runtime, warnings)
        return _theme_exit(action)

    return EXIT_USAGE, _theme_error(command, "usage", f"unknown theme command: {command}")


def _theme_exit(action: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    if action.get("ok") is True:
        return EXIT_OK, action
    return {
        "permission-denied": EXIT_DENIED,
        "conflict": EXIT_CONFLICT,
        "invalid-data": EXIT_INVALID_DATA,
        "unavailable": EXIT_UNAVAILABLE,
        "internal": EXIT_INTERNAL,
        "usage": EXIT_USAGE,
    }.get(action.get("code"), EXIT_INTERNAL), action


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

    settings = groups.add_parser("settings", help="settings commands reserved for a later phase")
    settings.add_argument("--json", action="store_true", dest="as_json")

    theme = groups.add_parser("theme", help="list, inspect, preview, apply and reset themes")
    theme_commands = theme.add_subparsers(dest="theme_command", required=True)
    for name in ("list", "reset"):
        child = theme_commands.add_parser(name)
        child.add_argument("--json", action="store_true", dest="as_json")
    for name in ("show", "preview", "apply"):
        child = theme_commands.add_parser(name)
        child.add_argument("theme")
        child.add_argument("--json", action="store_true", dest="as_json")

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

    if args.group == "settings":
        return EXIT_UNAVAILABLE, result(False, "unavailable", "The settings commands belong to a later phase."), as_json, False

    if args.group == "theme":
        code, action = run_theme(args)
        return code, action, as_json, False

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
