#!/usr/bin/env python3
"""Run a command that is terminated when its direct parent exits."""

from __future__ import annotations

import ctypes
import os
import signal
import sys


PR_SET_PDEATHSIG = 1


def arm(parent_pid: int) -> None:
    if parent_pid <= 1:
        raise RuntimeError("parent process has already exited")
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_PDEATHSIG) failed")
    if os.getppid() != parent_pid:
        raise RuntimeError("parent process exited while starting")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: parent_guard.py COMMAND [ARG ...]", file=sys.stderr)
        return 2
    arm(os.getppid())
    os.execvp(sys.argv[1], sys.argv[1:])
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
