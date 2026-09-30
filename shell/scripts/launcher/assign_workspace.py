#!/usr/bin/env python3
"""Move a newly opened launcher window to its captured workspace once."""

from __future__ import annotations

import json
import re
import subprocess
import sys
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
    """Assign a client only when its process carries a pending launch ID."""
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
        return False

    launch_id = environment.get(b"BLOX_LAUNCH_ID", b"").decode("ascii", errors="ignore")
    workspace_id = environment.get(b"BLOX_LAUNCH_WORKSPACE", b"").decode("ascii", errors="ignore")
    if not VALID_LAUNCH_ID.fullmatch(launch_id) or not VALID_WORKSPACE_ID.fullmatch(workspace_id):
        return False

    target_workspace = int(workspace_id)
    if target_workspace > MAX_WORKSPACE_ID:
        return False

    context_matches = any(
        isinstance(item, dict)
        and item.get("launchId") == launch_id
        and str(item.get("workspaceId")) == workspace_id
        for item in contexts
    )
    if not context_matches:
        return False

    current_workspace = (client.get("workspace") or {}).get("id")
    if str(current_workspace) != workspace_id:
        moved = run(
            [
                "hyprctl",
                "dispatch",
                f'hl.dsp.window.move({{ workspace = {target_workspace}, window = "address:{address}", follow = false }})',
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if moved.returncode != 0:
            return False

    run(
        [
            "hyprctl",
            "dispatch",
            f'hl.dsp.event("blox_launch_workspace_assigned>>{launch_id}")',
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return True


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    try:
        contexts = json.loads(sys.argv[2])
        if not isinstance(contexts, list):
            return 2
        assign_workspace(sys.argv[1], contexts)
    except json.JSONDecodeError:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
