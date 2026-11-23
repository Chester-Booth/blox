#!/usr/bin/env python3
"""Return explicit picker dismissal to the still-existing captured application."""

import json
import re
import subprocess
import sys


def restore(address: str, pid: int, window_class: str) -> bool:
    if not re.fullmatch(r"[0-9a-f]+", address) or pid <= 0 or not window_class:
        return False
    try:
        result = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=2, check=False)
        clients = json.loads(result.stdout)
        if result.returncode != 0 or not isinstance(clients, list):
            return False
        target = next((item for item in clients if isinstance(item, dict)
                       and str(item.get("address", "")).lower().removeprefix("0x") == address
                       and item.get("pid") == pid and item.get("class") == window_class), None)
        if target is None:
            return False
        expression = "hl.dispatch(hl.dsp.focus({window='address:0x" + address + "'}))"
        result = subprocess.run(["hyprctl", "eval", expression], capture_output=True, text=True, timeout=2, check=False)
        return result.returncode == 0
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


if __name__ == "__main__":
    try:
        success = len(sys.argv) == 4 and restore(sys.argv[1], int(sys.argv[2]), sys.argv[3])
    except ValueError:
        success = False
    raise SystemExit(0 if success else 1)
