#!/usr/bin/env python3
"""Launch a terminal desktop entry with its captured workspace context."""

from __future__ import annotations

import os
import sys

from desktop_exec import active_cursor_environment, launch_detached, valid_workspace_id


def main() -> int:
    if len(sys.argv) < 5:
        print(
            "Usage: command_exec.py <workspace-id> <launch-id> <working-directory> <command...>",
            file=sys.stderr,
        )
        return 2

    workspace_id = valid_workspace_id(sys.argv[1])
    launch_id = sys.argv[2]
    working_directory = sys.argv[3] or None
    command = ["kitty"]
    if not workspace_id:
        command.append("--detach")
    if working_directory:
        command.extend(("--directory", working_directory))
    command.extend(("--", *sys.argv[4:]))

    environment = os.environ.copy()
    environment.update(active_cursor_environment())
    return launch_detached(
        command,
        working_directory,
        environment,
        workspace_id=workspace_id,
        launch_id=launch_id,
    )


if __name__ == "__main__":
    raise SystemExit(main())
