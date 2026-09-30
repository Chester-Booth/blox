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
TRANSIENT_SERVICE_DESKTOP_IDS = {"t3code", "t3code-url-handler", "obsidian"}
VALID_ENVIRONMENT_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
VALID_LAUNCH_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
SESSION_ENVIRONMENT_NAMES = (
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_TYPE",
)
CURSOR_ENVIRONMENT_NAMES = (
    "XCURSOR_THEME",
    "XCURSOR_SIZE",
    "XCURSOR_PATH",
    "HYPRCURSOR_THEME",
    "HYPRCURSOR_SIZE",
)


def valid_workspace_id(value: str | int | None) -> int | None:
    """Return a Hyprland numeric workspace ID, or None for the usual launch path."""
    if value is None or isinstance(value, bool):
        return None
    try:
        workspace_id = int(value)
    except (TypeError, ValueError):
        return None
    return workspace_id if 1 <= workspace_id <= 2_147_483_647 else None


def _lua_string(value: str) -> str:
    return '"' + (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    ) + '"'


def _workspace_command(
    command: list[str],
    working_directory: str | None,
    environment: dict[str, str],
    workspace_id: int,
    launch_id: str | None,
) -> str:
    """Build a quoted shell command for Hyprland's per-process workspace rule."""
    overrides = {
        name: environment[name]
        for name in CURSOR_ENVIRONMENT_NAMES
        if name in environment
    }
    if launch_id and VALID_LAUNCH_ID.fullmatch(launch_id):
        overrides["BLOX_LAUNCH_ID"] = launch_id
        overrides["BLOX_LAUNCH_WORKSPACE"] = str(workspace_id)

    command_parts = ["env", "-u", "ELECTRON_RUN_AS_NODE"]
    command_parts.extend(f"{name}={value}" for name, value in overrides.items())
    command_parts.extend(command)
    result = shlex.join(command_parts)
    if working_directory:
        result = f"cd -- {shlex.quote(str(Path(working_directory).expanduser()))} && exec {result}"
        return result
    return f"exec {result}"


def _launch_with_workspace_rule(
    command: list[str],
    working_directory: str | None,
    environment: dict[str, str],
    workspace_id: int,
    launch_id: str | None,
) -> int:
    """Ask Hyprland to start a process with a one-shot workspace rule."""
    shell_command = _workspace_command(
        command, working_directory, environment, workspace_id, launch_id
    )
    expression = (
        "hl.dsp.exec_cmd("
        + _lua_string(shell_command)
        + ", { workspace = "
        + _lua_string(f"{workspace_id} silent")
        + " })"
    )
    result = subprocess.run(
        ["hyprctl", "dispatch", expression],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode


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
    Pass the compositor session variables explicitly, including
    ``XDG_SESSION_TYPE``. The value comes from the session; this launcher does
    not choose an application backend. Electron must not see
    ``ELECTRON_RUN_AS_NODE`` from a development shell.
    """
    ordered_environment = {
        name: environment[name]
        for name in SESSION_ENVIRONMENT_NAMES
        if name in environment
    }
    ordered_environment.update(
        (name, value)
        for name, value in environment.items()
        if name not in ordered_environment
    )
    return [
        f"--setenv={name}={value}"
        for name, value in ordered_environment.items()
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
    workspace_id: int | None = None,
    launch_id: str | None = None,
) -> int:
    """Start a desktop command with the lifetime it needs.

    Some desktop commands are short-lived clients which hand off to a lasting
    GUI process, such as Zed's ``zeditor`` CLI. T3 Code and Obsidian need their
    Electron processes kept outside Quickshell's cgroup so shell restarts do
    not kill them. Launch those apps through transient user services. Other
    workspace-aware launches use Hyprland's exec rule, then fall back to a
    detached process if the dispatcher is unavailable.
    """
    workspace_id = valid_workspace_id(workspace_id)
    if workspace_id and launch_id and VALID_LAUNCH_ID.fullmatch(launch_id):
        environment = dict(environment)
        environment["BLOX_LAUNCH_ID"] = launch_id
        environment["BLOX_LAUNCH_WORKSPACE"] = str(workspace_id)

    if _desktop_id_key(desktop_id) in TRANSIENT_SERVICE_DESKTOP_IDS:
        return _launch_in_transient_service(command, working_directory, environment, desktop_id or "t3code")

    if workspace_id and _launch_with_workspace_rule(
        command, working_directory, environment, workspace_id, launch_id
    ) == 0:
        return 0

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
    if len(sys.argv) not in (2, 4):
        print("Usage: desktop_exec.py <desktop-id> [workspace-id launch-id]", file=sys.stderr)
        return 2

    try:
        command, working_directory = resolve_command(sys.argv[1])
        launch_environment = os.environ.copy()
        launch_environment.update(active_cursor_environment())
        workspace_id = valid_workspace_id(sys.argv[2]) if len(sys.argv) == 4 else None
        launch_id = sys.argv[3] if len(sys.argv) == 4 else None
        if launch_id and not VALID_LAUNCH_ID.fullmatch(launch_id):
            launch_id = None
        return launch_detached(
            command,
            working_directory,
            launch_environment,
            sys.argv[1],
            workspace_id,
            launch_id,
        )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
