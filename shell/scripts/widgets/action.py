#!/usr/bin/env python3
"""Start native widget actions with validated configuration and argv launches."""

from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid


PACKAGE_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PACKAGE_ROOT / "widgets" / "lib"))
from blox_widgets.model import validate_profile  # noqa: E402
from blox_widgets.providers import FilesProvider  # noqa: E402
from blox_widgets.action_context import CONTEXT_ENV, ContextUnavailable, capture_context  # noqa: E402

MAX_INPUT_BYTES = 2 * 1024 * 1024
GUI_WORKFLOWS = {("todo", "edit"): 10, ("calendar", "open"): 120}


def file_command(settings: dict, requested: object) -> list[str]:
    """Only open a current listed child that resolves inside the configured root."""
    if not isinstance(requested, str) or not requested or len(requested) > 4096 or "\0" in requested:
        raise ValueError("Invalid file path")
    provider = FilesProvider(settings)
    observed = provider.sample(0)
    if not any(entry["path"] == requested for entry in observed["entries"]):
        raise ValueError("File is no longer in the widget listing")
    root = provider.path.resolve(strict=True)
    target = Path(requested).resolve(strict=True)
    if not target.is_relative_to(root) or target == root:
        raise ValueError("File is outside the configured directory")
    mode = target.stat().st_mode
    if not stat.S_ISDIR(mode) and (not stat.S_ISREG(mode) or mode & 0o111 or target.suffix.lower() == ".desktop"):
        raise ValueError("Executable and special files cannot be opened by a files widget")
    # A URI cannot become an opener option, including filenames beginning with '-'.
    return ["xdg-open", target.as_uri()]


def prepare_action(request: object, *, workflow=False):
    """Resolve an identity against the host's current widget, never payload commands."""
    if not isinstance(request, dict):
        raise ValueError("Invalid widget action")
    widget = validate_profile({"schemaVersion": 1, "widgets": [request.get("widget")]})["widgets"][0]
    if not widget["enabled"]:
        raise ValueError("Widget is disabled")
    payload = request.get("payload")
    if not isinstance(payload, dict):
        raise ValueError("Invalid action identity")
    if widget["kind"] == "files" and request.get("action") == "open":
        command = file_command(widget["settings"], payload.get("path"))
    elif widget["kind"] == "shortcuts" and request.get("action") == "launch":
        matches = [item for item in widget["settings"]["items"] if item["id"] == payload.get("id")]
        if len(matches) != 1:
            raise ValueError("Shortcut no longer exists")
        command = matches[0]["command"]
    elif widget["kind"] == "command" and request.get("action") == "activate":
        identity = request.get("identity")
        if (not isinstance(identity, dict) or set(identity) != {"widgetId", "consumerId", "generation", "button"}
                or identity["widgetId"] != widget["id"] or not isinstance(identity["consumerId"], str)
                or not identity["consumerId"] or len(identity["consumerId"]) > 128
                or type(identity["generation"]) is not int or not 0 <= identity["generation"] <= 2147483647
                or set(payload) != {"button"} or payload["button"] not in ("left", "right")
                or identity["button"] != payload["button"]):
            raise ValueError("Invalid command action identity")
        binding = widget["settings"]["actions"][payload["button"]]
        context = capture_context(request.get("hostContext"))
        if workflow:
            if (binding is None or binding["kind"] != "run"
                    or binding["command"][:1] != ["blox-widget-action"]
                    or tuple(binding["command"][1:]) not in GUI_WORKFLOWS):
                raise ValueError("Command action is no longer an application GUI workflow")
            binding = dict(binding)
            operation = tuple(binding["command"][1:])
            # Resolve the fixed helper from this tree, never an arbitrary PATH command.
            binding["command"] = [sys.executable, str(PACKAGE_ROOT / "shell/scripts/widgets/user_actions.py"), *operation]
            binding["timeoutSeconds"] = min(binding["timeoutSeconds"], GUI_WORKFLOWS[operation])
            return binding, context
        if binding is None or binding["kind"] != "launch":
            raise ValueError("Command action is no longer a launch binding")
        return binding["command"], context["workspace"]["id"]
    else:
        raise ValueError("Unsupported widget action")
    if workflow:
        raise ValueError("Only fixed command GUI workflows have application lifetime")
    workspace = request.get("workspaceId")
    workspace = workspace if type(workspace) is int and 1 <= workspace <= 2147483647 else None
    return command, workspace


def launch(command: list[str], workspace: int | None) -> int:
    """Use the launcher's argv quoting and captured-workspace placement."""
    sys.path.insert(0, str(PACKAGE_ROOT / "shell" / "scripts" / "launcher"))
    from desktop_exec import active_cursor_environment, launch_detached

    environment = dict(os.environ)
    environment.pop(CONTEXT_ENV, None)
    environment.update(active_cursor_environment())
    return launch_detached(command, None, environment, workspace_id=workspace,
                           launch_id="widget-" + uuid.uuid4().hex, timeout_seconds=5)


def run_workflow(binding, context):
    """Drain one service-owned finite invocation. Cleanup precedes completion."""
    from blox_widgets.command import OwnedInvocation

    invocation = OwnedInvocation(binding, trusted_context=context, retain_failed_output=True)
    cancelled = False

    def handle_terminate(_signum, _frame):
        nonlocal cancelled
        cancelled = True
        invocation.close()
        raise SystemExit(143)

    previous_sigterm = signal.signal(signal.SIGTERM, handle_terminate)
    try:
        while not cancelled:
            result = invocation.sample(time.monotonic())
            if result is not None:
                break
            time.sleep(.01)
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        invocation.close()
    if result["error"] and (result["error"] != f'Command exited with code {result["exitCode"]}' or not result["text"]):
        return {"ok": False, "code": "timeout" if "timed out" in result["error"] else "failed",
                "message": result["error"]}
    if len(result["text"]) > 8192:
        raise ValueError("Oversized workflow response")
    reply = json.loads(result["text"])
    if (not isinstance(reply, dict) or type(reply.get("ok")) is not bool
            or not isinstance(reply.get("code"), str) or not isinstance(reply.get("message"), str)):
        raise ValueError("Invalid workflow response")
    if reply["ok"] and result["exitCode"] != 0:
        raise ValueError("Workflow success disagrees with process exit")
    return reply


def protect_application_lifetime(expected_parent):
    """Shell death signals this runner so it tears down its finite process group."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "Cannot set workflow parent-death signal")
    if expected_parent <= 1 or os.getppid() != expected_parent:
        raise SystemExit(1)


def main(stream=None, output=None, launcher=None, *, workflow=False) -> int:
    stream = stream if stream is not None else sys.stdin.buffer
    output = output if output is not None else sys.stdout
    launcher = launcher if launcher is not None else launch
    try:
        line = stream.readline(MAX_INPUT_BYTES + 1)
        if len(line) > MAX_INPUT_BYTES:
            raise ValueError("Widget action is too large")
        command, workspace = prepare_action(json.loads(line), workflow=workflow)
        if workflow:
            reply = run_workflow(command, workspace)
        elif launcher(command, workspace):
            reply = {"ok": False, "code": "failed", "message": "Widget action did not start"}
        else:
            reply = {"ok": True, "code": "ok", "message": ""}
    except subprocess.TimeoutExpired:
        # A timed-out dispatcher may already have accepted the launch. Never retry.
        reply = {"ok": False, "code": "timeout", "message": "Could not confirm whether the application started"}
    except ContextUnavailable as error:
        reply = {"ok": False, "code": "unavailable", "message": str(error)}
    except (ValueError, OSError, ImportError) as error:
        reply = {"ok": False, "code": "invalid-data" if isinstance(error, ValueError) else "unavailable", "message": str(error)[:512]}
    output.write(json.dumps(reply) + "\n")
    return 0 if reply["ok"] else 1


if __name__ == "__main__":
    workflow = len(sys.argv) == 3 and sys.argv[1] == "--workflow" and sys.argv[2].isdigit()
    if sys.argv[1:] and not workflow:
        raise SystemExit("Unsupported widget action mode")
    if workflow:
        protect_application_lifetime(int(sys.argv[2]))
    raise SystemExit(main(workflow=workflow))
