#!/usr/bin/env python3
"""Launch the current Exec value for a desktop entry."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("GioUnix", "2.0")
from gi.repository import GioUnix  # noqa: E402


ARGUMENT_FIELD_CODES = re.compile(r"%[fFuUdDnNvm]")


def resolve_command(desktop_id: str) -> tuple[list[str], str | None]:
    entry_id = desktop_id if desktop_id.endswith(".desktop") else f"{desktop_id}.desktop"
    entry = GioUnix.DesktopAppInfo.new(entry_id)
    if entry is None:
        raise ValueError(f"Desktop entry not found: {entry_id}")

    command: list[str] = []
    for token in shlex.split(entry.get_string("Exec") or ""):
        if token == "%i":
            icon = entry.get_string("Icon") or ""
            if icon:
                command.extend(("--icon", icon))
            continue

        token = token.replace("%%", "\0")
        token = token.replace("%c", entry.get_name() or "")
        token = token.replace("%k", entry.get_filename() or "")
        token = ARGUMENT_FIELD_CODES.sub("", token).replace("\0", "%")
        if token:
            command.append(token)

    if not command:
        raise ValueError(f"Desktop entry has no executable command: {entry_id}")

    working_directory = entry.get_string("Path") or None
    if entry.get_boolean("Terminal"):
        terminal = ["kitty", "--detach"]
        if working_directory:
            terminal.extend(("--directory", working_directory))
            working_directory = None
        command = terminal + command

    return command, working_directory


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: desktop_exec.py <desktop-id>", file=sys.stderr)
        return 2

    try:
        command, working_directory = resolve_command(sys.argv[1])
        service_command = ["systemd-run", "--user", "--collect", "--quiet"]
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE"):
            value = os.environ.get(name)
            if value:
                service_command.append(f"--setenv={name}={value}")
        if working_directory:
            service_command.extend(("--working-directory", str(Path(working_directory).expanduser())))
        service_command.extend(("--", *command))
        return subprocess.run(service_command, check=False).returncode
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
