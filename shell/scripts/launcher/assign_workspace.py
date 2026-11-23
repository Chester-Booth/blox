#!/usr/bin/env python3
"""Move a newly opened launcher window to its captured workspace once."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable


VALID_ADDRESS = re.compile(r"^0x[0-9a-fA-F]+$")
VALID_LAUNCH_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
VALID_WORKSPACE_ID = re.compile(r"^[1-9][0-9]*$")
MAX_WORKSPACE_ID = 2_147_483_647


def _environment_for(pid: int, proc_root: Path) -> dict[bytes, bytes]:
    values = (proc_root / str(pid) / "environ").read_bytes().split(b"\0")
    environment: dict[bytes, bytes] = {}
    for value in values:
        if b"=" in value:
            key, item = value.split(b"=", 1)
            environment[key] = item
    return environment


def assign_workspace(
    address: str,
    contexts: list[dict[str, object]],
    *,
    proc_root: Path = Path("/proc"),
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> bool:
    """Match launch tags, or one pending desktop identity for sandboxed apps."""
    if not VALID_ADDRESS.fullmatch(address):
        return False

    try:
        result = run(
            ["hyprctl", "clients", "-j"],
            check=True,
            capture_output=True,
            text=True,
        )
        clients = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return False

    client = next(
        (item for item in clients if str(item.get("address", "")).lower() == address.lower()),
        None,
    )
    if not client:
        return False
    try:
        environment = _environment_for(int(client["pid"]), proc_root)
    except (KeyError, OSError, ValueError):
        environment = {}

    launch_id = environment.get(b"BLOX_LAUNCH_ID", b"").decode("ascii", errors="ignore")
    workspace_id = environment.get(b"BLOX_LAUNCH_WORKSPACE", b"").decode("ascii", errors="ignore")
    matches = [
        item for item in contexts if
        isinstance(item, dict)
        and item.get("launchId") == launch_id
        and str(item.get("workspaceId")) == workspace_id
    ] if launch_id else []
    if not matches:
        if launch_id or workspace_id:
            return False
        # Flatpak and single-instance handoffs can discard the caller's env.
        # Only new windows with one unambiguous pending app identity qualify.
        def identity(value):
            return str(value or "").casefold().removesuffix(".desktop")
        classes = {identity(client.get(key)) for key in ("class", "initialClass")} - {""}
        matches = [item for item in contexts if isinstance(item, dict)
            and address.lower().removeprefix("0x") not in {str(a).lower().removeprefix("0x") for a in item.get("existingAddresses", [])}
            and classes.intersection({identity(item.get("desktopId")), identity(item.get("startupClass"))} - {""})]
    if len(matches) != 1:
        return False
    launch_id = str(matches[0].get("launchId", ""))
    workspace_id = str(matches[0].get("workspaceId", ""))
    if not VALID_LAUNCH_ID.fullmatch(launch_id) or not VALID_WORKSPACE_ID.fullmatch(workspace_id):
        return False
    target_workspace = int(workspace_id)
    if target_workspace > MAX_WORKSPACE_ID:
        return False

    current_workspace = (client.get("workspace") or {}).get("id")
    if str(current_workspace) != workspace_id:
        moved = run(
            [
                "hyprctl",
                "eval",
                "hl.dispatch(hl.dsp.window.move({ "
                f'workspace = {target_workspace}, window = "address:{address}", follow = false'
                " }))",
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if moved.returncode != 0:
            return False

    acknowledged = run(
        [
            "hyprctl",
            "eval",
            f'hl.dispatch(hl.dsp.event("blox_launch_workspace_assigned>>{launch_id}"))',
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return acknowledged.returncode == 0


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    if sys.argv[1] == "--release":
        if not VALID_LAUNCH_ID.fullmatch(sys.argv[2]):
            return 2
        expression = (
            "for key,item in pairs(blox_launcher_rules or {}) do "
            f'if item.launchId == "{sys.argv[2]}" then '
            "item.rule:set_enabled(false); item.timer:set_enabled(false); "
            "blox_launcher_rules[key] = nil end end"
        )
        return subprocess.run(["hyprctl", "eval", expression], check=False,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    try:
        contexts = json.loads(sys.argv[2])
        if not isinstance(contexts, list):
            return 2
        # The compositor event can arrive before its client snapshot or PID.
        for attempt in range(8):
            if assign_workspace(sys.argv[1], contexts):
                break
            if attempt < 7:
                time.sleep(0.1)
    except json.JSONDecodeError:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
