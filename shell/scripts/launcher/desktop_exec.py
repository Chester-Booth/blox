#!/usr/bin/env python3
"""Launch the current Exec value for a desktop entry."""

from __future__ import annotations

import json
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


def active_cursor_environment() -> dict[str, str]:
    """Pass the active cursor choice to applications launched from the menu."""
    state_root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")).expanduser()
    metadata_path = state_root / "blox-theme/current/cursor/metadata.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    theme = metadata.get("theme_name")
    size = metadata.get("size")
    if not isinstance(theme, str) or not theme or not isinstance(size, int):
        return {}
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()
    cursor_path = [
        data_home / "icons",
        Path.home() / ".icons",
        Path("/usr/local/share/icons"),
        Path("/usr/share/icons"),
        Path("/usr/share/pixmaps"),
    ]
    path_entries = [str(path) for path in cursor_path]
    for entry in os.environ.get("XCURSOR_PATH", "").split(":"):
        if entry and entry not in path_entries:
            path_entries.append(entry)
    environment = {
        "XCURSOR_THEME": theme,
        "XCURSOR_SIZE": str(size),
        "XCURSOR_PATH": ":".join(path_entries),
    }
    if metadata.get("format") == "xcursor+hyprcursor-v1":
        environment.update({"HYPRCURSOR_THEME": theme, "HYPRCURSOR_SIZE": str(size)})
    return environment


def _launches_code(desktop_id: str, command: list[str]) -> bool:
    """Keep Code out of the transient systemd scope used by the app menu."""
    entry_name = Path(desktop_id.removesuffix(".desktop")).name.lower()
    executable_name = Path(command[0]).name.lower() if command else ""
    return entry_name in {"code", "code-url-handler"} and executable_name in {"code", "code-insiders"}


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: desktop_exec.py <desktop-id>", file=sys.stderr)
        return 2

    try:
        command, working_directory = resolve_command(sys.argv[1])
        launch_environment = os.environ.copy()
        launch_environment.update(active_cursor_environment())
        if _launches_code(sys.argv[1], command):
            process = subprocess.Popen(
                command,
                cwd=str(Path(working_directory).expanduser()) if working_directory else None,
                env=launch_environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return 0 if process.pid > 0 else 1
        service_command = ["systemd-run", "--user", "--collect", "--quiet"]
        inherited = {name: os.environ.get(name) for name in ("DISPLAY", "WAYLAND_DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE")}
        inherited.update(active_cursor_environment())
        for name, value in inherited.items():
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
