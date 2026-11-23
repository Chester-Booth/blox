"""Process-group ownership for widget commands and PTY terminal sessions.

Widget processes run inside quickshell.service's systemd user cgroup, so systemd
already cleans up the entire tree on service stop or restart. Each invocation
gets its own session and process group plus PR_SET_PDEATHSIG so cancelling a
widget or losing the broker tears down the process group cleanly.
"""
from __future__ import annotations

import ctypes
import errno
import fcntl
import math
import os
import pty
import signal
import struct
import subprocess
import termios
import time

CLEANUP_SECONDS = 1.0
PR_SET_PDEATHSIG = 1

_LIBC = ctypes.CDLL(None, use_errno=True)


class OwnershipUnavailable(OSError):
    """Raised when owned widget execution cannot start."""


class CleanupFailed(OwnershipUnavailable):
    """Raised when a stopped process group cannot be torn down."""


class InvocationLaunchError(OSError):
    """Raised when a configured working directory or executable fails to launch."""

    def __init__(self, number, message, *, phase="exec"):
        super().__init__(number, message)
        self.phase = phase


def _set_pdeathsig():
    _LIBC.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0)


def _set_pty_size(fd: int, columns: int, rows: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", max(1, rows), max(1, columns), 0, 0))


class OwnedProcess:
    """One owned command or terminal process group with pidfd exit tracking."""

    def __init__(self, proc: subprocess.Popen, *, master_fd: int = -1, deadline=None):
        self._proc = proc
        self.pid = proc.pid
        self.pgid = proc.pid
        self.stdout = proc.stdout
        self.stderr = proc.stderr
        self.fd = master_fd
        self.deadline = deadline
        self.returncode = None
        self.closed = False
        try:
            self.exit_fd = os.pidfd_open(self.pid)
        except OSError:
            self.exit_fd = None

    def poll(self):
        if self.returncode is None:
            code = self._proc.poll()
            if code is not None:
                self.returncode = code
        return self.returncode

    def limit(self, deadline) -> None:
        self.deadline = deadline

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            if self.poll() is None:
                try:
                    os.killpg(self.pgid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                end = time.monotonic() + 0.15
                while self.poll() is None and time.monotonic() < end:
                    time.sleep(0.005)
            # Always SIGKILL the whole process group so forked descendants die
            # even when the leader already exited.
            try:
                os.killpg(self.pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if self.poll() is None:
                try:
                    self.returncode = self._proc.wait(timeout=CLEANUP_SECONDS)
                except subprocess.TimeoutExpired:
                    self.returncode = self._proc.poll()
        finally:
            if self.fd >= 0:
                try:
                    os.close(self.fd)
                except OSError:
                    pass
                self.fd = -1
            if self.exit_fd is not None:
                try:
                    os.close(self.exit_fd)
                except OSError:
                    pass
                self.exit_fd = None
            for stream in (self.stdout, self.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass


def _validate_cwd(cwd: str) -> str | None:
    if not cwd:
        return None
    if not os.path.isdir(cwd):
        raise InvocationLaunchError(errno.ENOENT, f"Invalid working directory: {cwd}", phase="cwd")
    return cwd


def launch(command, environment, cwd, deadline=None, *, terminal=None) -> OwnedProcess:
    """Spawn a widget command or PTY terminal in its own process group."""
    if not isinstance(command, (list, tuple)) or not command or not all(isinstance(arg, str) for arg in command):
        raise InvocationLaunchError(errno.EINVAL, "Invalid command", phase="exec")
    resolved_cwd = _validate_cwd(cwd or "")
    env = {k: str(v) for k, v in (environment or os.environ).items()
           if k not in ("NOTIFY_SOCKET", "WATCHDOG_PID", "WATCHDOG_USEC")}

    if terminal is None:
        def _child_setup():
            os.setsid()
            _set_pdeathsig()

        try:
            proc = subprocess.Popen(
                list(command),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=resolved_cwd,
                env=env,
                preexec_fn=_child_setup,
                close_fds=True,
            )
        except OSError as error:
            raise InvocationLaunchError(error.errno or errno.ENOENT, str(error), phase="exec") from error
        return OwnedProcess(proc, deadline=deadline)

    columns = int(terminal.get("columns", 80))
    rows = int(terminal.get("rows", 24))
    master_fd, slave_fd = pty.openpty()
    try:
        _set_pty_size(slave_fd, columns, rows)

        def _pty_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            signal.signal(signal.SIGHUP, signal.SIG_DFL)

        try:
            proc = subprocess.Popen(
                list(command),
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd=resolved_cwd,
                env=env,
                preexec_fn=_pty_setup,
                close_fds=True,
            )
        except OSError as error:
            raise InvocationLaunchError(error.errno or errno.ENOENT, str(error), phase="exec") from error
    except BaseException:
        os.close(master_fd)
        raise
    finally:
        os.close(slave_fd)
    return OwnedProcess(proc, master_fd=master_fd, deadline=deadline)


def maintain_owner() -> None:
    """No-op hook retained for broker loop clarity."""


def owner_delay() -> float | None:
    """No periodic lease renewal is required without an external daemon."""
    return None


def fail_service() -> None:
    """No external supervisor connection to tear down."""
