#!/usr/bin/env python3
"""Focus the newest matching Hyprland window, if one exists."""

import json
import subprocess
import sys


def normalise(value: str) -> str:
    return value.casefold().removesuffix(".desktop")


def main() -> int:
    wanted = {normalise(value) for value in sys.argv[1:] if value}
    clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"]))
    matches = [
        client
        for client in clients
        if wanted.intersection(
            normalise(str(client.get(key, "")))
            for key in ("class", "initialClass")
        )
    ]
    if not matches:
        return 3
    match = min(matches, key=lambda client: client.get("focusHistoryID", 999999))
    return subprocess.run(
        ["hyprctl", "dispatch", "focuswindow", f"address:{match['address']}"],
        check=False,
        stdout=subprocess.DEVNULL,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
