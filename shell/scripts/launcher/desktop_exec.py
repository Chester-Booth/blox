#!/usr/bin/env python3
"""Launch the current Exec value for a desktop entry."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import uuid
from pathlib import Path

import gi

gi.require_version("GioUnix", "2.0")
from gi.repository import GioUnix  # noqa: E402


ARGUMENT_FIELD_CODES = re.compile(r"%[fFuUdDnNvm]")
TRANSIENT_SERVICE_DESKTOP_IDS = {"t3code", "t3code-url-handler"}
VALID_ENVIRONMENT_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


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
    metadata_path = state_root / "blox/theme/current/cursor/metadata.json"
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


def _desktop_id_key(desktop_id: str | None) -> str:
    return (desktop_id or "").removesuffix(".desktop").casefold()


def _systemd_environment_args(environment: dict[str, str]) -> list[str]:
    """Pass the launch environment into a transient user service.

    ``systemd-run`` does not inherit the caller's environment for a service.
    Keep the session variables supplied by the user service and add the
    cursor/theme values that the launcher calculated. Electron must not see
    ``ELECTRON_RUN_AS_NODE`` from a development shell.
    """
    return [
        f"--setenv={name}={value}"
        for name, value in environment.items()
        if name != "ELECTRON_RUN_AS_NODE" and VALID_ENVIRONMENT_NAME.fullmatch(name)
    ]


def _launch_in_transient_service(
    command: list[str],
    working_directory: str | None,
    environment: dict[str, str],
    desktop_id: str,
) -> int:
    """Start a long-lived GUI in a cgroup independent of Quickshell."""
    unit = f"blox-desktop-{_desktop_id_key(desktop_id)}-{os.getpid()}-{uuid.uuid4().hex[:8]}.service"
    systemd_command = [
        "systemd-run",
        "--user",
        "--collect",
        "--no-block",
        "--quiet",
        f"--unit={unit}",
        *_systemd_environment_args(environment),
    ]
    if working_directory:
        systemd_command.append(f"--working-directory={Path(working_directory).expanduser()}")
    systemd_command.extend(("--", *command))
    result = subprocess.run(
        systemd_command,
        cwd=str(Path(working_directory).expanduser()) if working_directory else None,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode


def launch_detached(
    command: list[str],
    working_directory: str | None,
    environment: dict[str, str],
    desktop_id: str | None = None,
) -> int:
    """Start a desktop command with the lifetime it needs.

    Some desktop commands are short-lived clients which hand off to a lasting
    GUI process, such as Zed's ``zeditor`` CLI. T3 Code is different: its
    Electron children must share a cgroup that Quickshell cannot kill when the
    shell restarts. Launch T3 through a transient user service for that case;
    use a detached process for the other desktop entries.
    """
    if _desktop_id_key(desktop_id) in TRANSIENT_SERVICE_DESKTOP_IDS:
        return _launch_in_transient_service(command, working_directory, environment, desktop_id or "t3code")

    process = subprocess.Popen(
        command,
        cwd=str(Path(working_directory).expanduser()) if working_directory else None,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return 0 if process.pid > 0 else 1


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: desktop_exec.py <desktop-id>", file=sys.stderr)
        return 2

    try:
        command, working_directory = resolve_command(sys.argv[1])
        launch_environment = os.environ.copy()
        launch_environment.update(active_cursor_environment())
        return launch_detached(command, working_directory, launch_environment, sys.argv[1])
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
