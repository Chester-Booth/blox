#!/usr/bin/env python3
"""Small public CLI adapter for the supervised Blox shell action owner."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
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
        "usage": EXIT_USAGE,
        "permission-denied": EXIT_DENIED,
        "denied": EXIT_DENIED,
        "conflict": EXIT_CONFLICT,
        "busy": EXIT_CONFLICT,
        "stale": EXIT_CONFLICT,
        "timeout": EXIT_CONFLICT,
        "invalid-data": EXIT_INVALID_DATA,
        "unavailable": EXIT_UNAVAILABLE,
    }.get(action.get("code"), EXIT_INTERNAL)


def call_owner(method: str = "status", arguments: list[str] | None = None,
               target: str = "blox") -> dict[str, Any]:
    command = [str(IPC), target, method, *(arguments or [])]
    try:
        completed = subprocess.run(
            command,
            cwd=SCRIPT_ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return result(False, "timeout", "The Blox shell action did not finish before the deadline.")
    except OSError:
        return result(False, "unavailable", "The Blox shell is not running.")

    if completed.returncode != 0:
        data = {"ownerAbsent": True} if completed.returncode == 3 else None
        return result(False, "unavailable", "The Blox shell action is unavailable.", data)

    try:
        action = json.loads(completed.stdout.strip())
    except json.JSONDecodeError:
        return result(False, "invalid-data", "The Blox shell returned invalid action data.")

    if not isinstance(action, dict):
        return result(False, "invalid-data", "The Blox shell returned a non-object action result.")
    required = {"version", "ok", "code", "message", "data"}
    if (set(action) != required or type(action["version"]) is not int or action["version"] != 1
            or not isinstance(action["ok"], bool)
            or not isinstance(action["code"], str) or not action["code"]
            or not isinstance(action["message"], str)):
        return result(False, "invalid-data", "The Blox shell returned an invalid action result.")
    return action


def run_audio(args) -> tuple[int, dict[str, Any]]:
    operation = args.audio_command
    value = getattr(args, "value", "")
    action = call_owner("audio", [operation, value])
    return exit_code(action), action


def run_network(args) -> tuple[int, dict[str, Any]]:
    operation = args.network_command
    value = getattr(args, "value", "")
    action = call_owner("network", [operation, value])
    return exit_code(action), action


def run_bluetooth(args) -> tuple[int, dict[str, Any]]:
    operation = args.bluetooth_command
    value = getattr(args, "value", "")
    action = call_owner("bluetooth", [operation, value])
    return exit_code(action), action


def run_gpu(args) -> tuple[int, dict[str, Any]]:
    action = call_owner("gpu", [args.gpu_command, args.mode])
    return exit_code(action), action


def run_display(args) -> tuple[int, dict[str, Any]]:
    action = call_owner("monitor", [args.display_command, args.monitor, args.rate])
    return exit_code(action), action


def run_settings(args) -> tuple[int, dict[str, Any]]:
    operation = args.settings_command
    if operation == "get":
        request = {}
    elif operation == "apply-widgets":
        request = {"expectedRevision": args.revision}
    elif operation == "set":
        request = {"path": args.path, "valueJson": args.value, "expectedRevision": args.revision}
    else:
        request = {"section": args.section, "expectedRevision": args.revision}

    started = call_owner("begin", [operation, json.dumps(request, separators=(",", ":"))], target="settings")
    if started.get("code") != "pending":
        return exit_code(started), started
    request_id = started.get("data", {}).get("requestId") if isinstance(started.get("data"), dict) else None
    if not isinstance(request_id, str) or not request_id:
        action = result(False, "invalid-data", "The Settings owner returned an invalid request id.")
        return EXIT_INVALID_DATA, action

    deadline = time.monotonic() + 9.0
    while time.monotonic() < deadline:
        action = call_owner("poll", [request_id], target="settings")
        if action.get("code") != "pending":
            return exit_code(action), action
        time.sleep(0.05)
    action = result(False, "timeout", "The Settings transaction did not finish before the deadline.", {"requestId": request_id})
    return exit_code(action), action


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


def _apply_backend(action: str, theme_id: str = "") -> dict[str, Any]:
    command = [sys.executable, str(SCRIPT_ROOT / "apply_runtime.py"), action]
    if theme_id:
        command += ["--theme", theme_id]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=180, check=False)
        records = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        response = next((record for record in reversed(records) if "event" not in record), None)
        if not isinstance(response, dict) or response.get("version") != 1:
            raise ValueError("invalid Apply result")
        return result(response.get("ok") is True, str(response.get("code", "failed")),
                      str(response.get("error", "")), response.get("data"))
    except subprocess.TimeoutExpired:
        return result(False, "timeout", "Apply timed out. Check Settings recovery before retrying.")
    except (OSError, ValueError, TypeError):
        return result(False, "invalid-data", "Could not read the durable Apply result. Check Settings recovery.")


def _public_apply(command: str, path, theme, core, runtime, extra_warnings: list[str] | None = None):
    owner = call_owner("begin", [theme["id"], str(path)], target="settingsApply")
    if owner.get("code") == "pending":
        request_id = (owner.get("data") or {}).get("requestId")
        if not isinstance(request_id, str) or not request_id:
            return result(False, "invalid-data", "The Apply owner returned an invalid request id.")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            receipt = call_owner("poll", [request_id], target="settingsApply")
            if receipt.get("code") != "pending":
                return receipt
            time.sleep(0.05)
        return result(False, "timeout", "Apply is still pending. Check Settings before retrying.", {"requestId": request_id})
    if owner.get("code") != "unavailable":
        return owner
    # A missing method in a running shell is not permission to bypass that shell.
    presence = call_owner()
    if presence.get("code") != "unavailable" or not isinstance(presence.get("data"), dict) or presence["data"].get("ownerAbsent") is not True:
        return result(False, "unavailable", "The running shell has no ready Settings Apply owner.")
    preview = Path(os.environ.get("BLOX_HYPRLAND_PREVIEW_STATE") or
                   str(Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "blox-theme-hyprland-preview.json"))
    if os.path.lexists(preview):
        return result(False, "conflict", "Restore the retained Hyprland preview in Settings before applying.")
    status = _apply_backend("status")
    if not status["ok"] or status["data"] is not None:
        return result(False, "conflict", "Resolve the retained Apply transaction in Settings before applying.", status["data"])
    review = _apply_backend("review", str(path))
    if not review["ok"]:
        return review
    if (review["data"] or {}).get("scripts") or (review["data"] or {}).get("drift"):
        return result(False, "conflict", "Open Settings to review scripts or external changes before applying.", review["data"])
    applied = _apply_backend("apply", str(path))
    if applied["ok"] and isinstance(applied["data"], dict) and applied["data"].get("phase") == "complete":
        finished = _apply_backend("finish")
        if not finished["ok"]:
            return finished
    if applied["ok"] and isinstance(applied["data"], dict) and applied["data"].get("phase") != "complete":
        return result(False, "failed", "Review failed targets in Settings.", applied["data"])
    return applied


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

    audio = groups.add_parser("audio", help="audio actions through the running shell")
    audio_commands = audio.add_subparsers(dest="audio_command", required=True)
    audio_toggle = audio_commands.add_parser("toggle-mute")
    audio_toggle.add_argument("--json", action="store_true", dest="as_json")
    audio_volume = audio_commands.add_parser("set-volume")
    audio_volume.add_argument("value")
    audio_volume.add_argument("--json", action="store_true", dest="as_json")
    audio_mic = audio_commands.add_parser("set-mic")
    audio_mic.add_argument("value", choices=("open", "muted"))
    audio_mic.add_argument("--json", action="store_true", dest="as_json")

    for name in ("toggle-mic", "adjust-volume"):
        child = audio_commands.add_parser(name)
        if name == "adjust-volume":
            child.add_argument("value")
        child.add_argument("--json", action="store_true", dest="as_json")

    hardware_commands = {"brightness": {"set": True, "adjust": True},
                         "touchpad": {"set": True, "toggle": False},
                         "vendor": {"set-profile": True, "set-fan-curves": True},
                         "power-profile": {"set": True},
                         "night-light": {"set": True, "toggle": False, "restore": False},
                         "caffeine": {"set": True}}
    for domain, operations in hardware_commands.items():
        group = groups.add_parser(domain)
        commands = group.add_subparsers(dest="hardware_command", required=True)
        for operation, needs_value in operations.items():
            child = commands.add_parser(operation)
            if needs_value:
                child.add_argument("value")
            child.add_argument("--json", action="store_true", dest="as_json")

    network = groups.add_parser("network", help="NetworkManager actions through the running shell")
    network_commands = network.add_subparsers(dest="network_command", required=True)
    network_toggle = network_commands.add_parser("toggle-wifi")
    network_toggle.add_argument("--json", action="store_true", dest="as_json")
    network_wifi = network_commands.add_parser("set-wifi")
    network_wifi.add_argument("value", choices=("on", "off"))
    network_wifi.add_argument("--json", action="store_true", dest="as_json")

    bluetooth = groups.add_parser("bluetooth", help="BlueZ actions through the running shell")
    bluetooth_commands = bluetooth.add_subparsers(dest="bluetooth_command", required=True)
    bluetooth_toggle = bluetooth_commands.add_parser("toggle-enabled")
    bluetooth_toggle.add_argument("--json", action="store_true", dest="as_json")
    bluetooth_enabled = bluetooth_commands.add_parser("set-enabled")
    bluetooth_enabled.add_argument("value", choices=("on", "off"))
    bluetooth_enabled.add_argument("--json", action="store_true", dest="as_json")

    gpu = groups.add_parser("gpu", help="GPU mode actions through the running shell")
    gpu_commands = gpu.add_subparsers(dest="gpu_command", required=True)
    gpu_mode = gpu_commands.add_parser("set-mode")
    gpu_mode.add_argument("mode", choices=("dedicated", "hybrid", "integrated"))
    gpu_mode.add_argument("--json", action="store_true", dest="as_json")

    display = groups.add_parser("display", help="monitor actions through the running shell")
    display_commands = display.add_subparsers(dest="display_command", required=True)
    display_refresh = display_commands.add_parser("set-refresh")
    display_refresh.add_argument("monitor")
    display_refresh.add_argument("rate")
    display_refresh.add_argument("--json", action="store_true", dest="as_json")

    doctor = groups.add_parser("doctor", help="local install health report")
    doctor.add_argument("--json", action="store_true", dest="as_json")

    settings = groups.add_parser("settings", help="read and change Settings through the running shell owner")
    settings_commands = settings.add_subparsers(dest="settings_command", required=True)
    settings_get = settings_commands.add_parser("get")
    settings_get.add_argument("--json", action="store_true", dest="as_json")
    settings_set = settings_commands.add_parser("set")
    settings_set.add_argument("path")
    settings_set.add_argument("value", help="value encoded as JSON")
    settings_set.add_argument("--revision", type=int, required=True)
    settings_set.add_argument("--json", action="store_true", dest="as_json")
    settings_widgets = settings_commands.add_parser("apply-widgets")
    settings_widgets.add_argument("--revision", type=int, required=True)
    settings_widgets.add_argument("--json", action="store_true", dest="as_json")
    settings_reset = settings_commands.add_parser("reset")
    settings_reset.add_argument("section", nargs="?")
    settings_reset.add_argument("--revision", type=int, required=True)
    settings_reset.add_argument("--json", action="store_true", dest="as_json")

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
        return int(error.code), result(False, "usage", "Use: bloxctl {status|audio|network|bluetooth|gpu|display|doctor|settings|theme|lifecycle} --help."), "--json" in argv, False

    as_json = getattr(args, "as_json", False)

    if args.group == "status":
        action = call_owner()
        return exit_code(action), action, as_json, False

    if args.group == "audio":
        code, action = run_audio(args)
        return code, action, as_json, False

    if args.group == "network":
        code, action = run_network(args)
        return code, action, as_json, False

    if args.group == "bluetooth":
        code, action = run_bluetooth(args)
        return code, action, as_json, False

    if args.group == "gpu":
        code, action = run_gpu(args)
        return code, action, as_json, False

    if args.group == "display":
        code, action = run_display(args)
        return code, action, as_json, False

    if args.group in ("brightness", "touchpad", "vendor", "power-profile", "night-light", "caffeine"):
        owner = {"power-profile": "powerProfile", "night-light": "nightLight"}.get(args.group, args.group)
        action = call_owner(owner, [args.hardware_command, getattr(args, "value", "")])
        return exit_code(action), action, as_json, False

    if args.group == "doctor":
        code, action, printed = run_doctor(as_json)
        return code, action, as_json, printed

    if args.group == "settings":
        code, action = run_settings(args)
        return code, action, as_json, False

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

    return EXIT_USAGE, result(False, "usage", "Use: bloxctl {status|audio|network|bluetooth|gpu|display|doctor|settings|theme|lifecycle} --help."), as_json, False


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
