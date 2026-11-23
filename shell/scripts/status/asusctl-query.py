#!/usr/bin/env python3
"""Capture the vendor status queries before forwarding output to the shell."""

import ctypes
import os
import resource
import signal
import subprocess
import sys
import tempfile
import time


OUTPUT_LIMIT = 64 * 1024
QUERY_TIMEOUT = 2
STATUS_TIMEOUT = 6
QUERIES = [("profile", "list"), ("profile", "get"), ("fan-curve", "--get-enabled")]


def limit_output():
    # This process is single threaded. Apply the limit only in the child.
    resource.setrlimit(resource.RLIMIT_FSIZE, (OUTPUT_LIMIT, OUTPUT_LIMIT))
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)


def cancelled(number, _frame):
    raise SystemExit(128 + number)


def kill_group(*_):
    os.killpg(0, signal.SIGKILL)


def diagnostic(message):
    try:
        os.write(2, (message + "\n").encode("utf-8", errors="replace")[:4096])
    except OSError:
        # A command may already have filled the bounded diagnostic file.
        pass


def supervise(parent, status_fd, deadline, arguments):
    """Own the group until cleanup, even after the direct command exits."""
    os.set_inheritable(status_fd, False)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, kill_group)
    # Match command.py's ownership pattern without importing widget code. The
    # expected-parent check also covers death before prctl registered the signal.
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Cannot set query parent-death signal")
        if os.getppid() != parent:
            kill_group()
        # Supervisor diagnostics must obey the same file bound as the command.
        limit_output()
        code = 127
        try:
            if time.monotonic() >= deadline:
                code = 124
            else:
                process = subprocess.Popen(["asusctl", *arguments], stdin=subprocess.DEVNULL,
                                           preexec_fn=limit_output)
                try:
                    code = process.wait(timeout=max(0, deadline - time.monotonic()))
                    code = code if code >= 0 else 128 - code
                except subprocess.TimeoutExpired:
                    code = 124
            if code == 124:
                diagnostic("query timed out; sending signal SIGKILL to query group")
        except OSError as error:
            diagnostic(str(error))
        # Status uses its own private regular file. No command output or
        # ownership lifetime depends on a pipe or on the capture owner running.
        os.write(status_fd, str(code).encode("ascii"))
    finally:
        kill_group()


def capture(arguments):
    """Keep both child streams off pipes, including after owner cancellation."""
    parent = os.getppid()
    process = None
    deadline = min(time.monotonic() + QUERY_TIMEOUT,
                   float(os.environ.get("BLOX_ASUSCTL_DEADLINE", "inf")))
    # TemporaryFile creates private, unlinked regular files. Even SIGKILL leaves
    # no paths behind, and open child descriptors remain writable during teardown.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors, tempfile.TemporaryFile() as status:
        try:
            process = subprocess.Popen(
                [sys.executable, __file__, "--supervise", str(os.getpid()), str(status.fileno()), str(deadline), *arguments],
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=output if arguments[0] == "fan-curve" else errors,
                start_new_session=True,
                pass_fds=(status.fileno(),),
            )
            while True:
                try:
                    process.wait(timeout=0.05)
                    break
                except subprocess.TimeoutExpired:
                    if os.getppid() != parent:
                        raise SystemExit(143)
        finally:
            if process is not None:
                # Only the live supervisor signals its own group. It never
                # gives up ownership before cleanup, even on direct-child exit.
                # Owner SIGKILL is covered by the supervisor's prctl above.
                process.terminate()
                process.wait()
        status.seek(0)
        result = status.read(32)
        code = int(result) if result else 1
        output.seek(0)
        errors.seek(0)
        raw = output.read(OUTPUT_LIMIT)
        diagnostic = errors.read(OUTPUT_LIMIT)
        if len(raw) == OUTPUT_LIMIT or len(diagnostic) == OUTPUT_LIMIT:
            code = code or 1
            diagnostic = b"output limit reached; " + diagnostic
        if code:
            detail = (diagnostic or raw or b"no diagnostic output")[:4096]
            print(f"asusctl {' '.join(arguments)} failed, status {code}: "
                  + detail.decode("utf-8", errors="replace").strip(), file=sys.stderr)
        elif diagnostic:
            print(diagnostic[:4096].decode("utf-8", errors="replace").strip(), file=sys.stderr)
        # Only the capture owner writes into the caller's pipe, after asusctl
        # and its process group have finished using the regular files.
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()
        return code if 0 <= code <= 255 else 1


def main():
    if sys.argv[1:] == ["--deadline"]:
        print(time.monotonic() + STATUS_TIMEOUT)
        return 0
    if len(sys.argv) == 7 and sys.argv[1] == "--supervise" and tuple(sys.argv[5:]) in QUERIES:
        supervise(int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), tuple(sys.argv[5:]))
        return 1
    arguments = tuple(sys.argv[1:])
    if arguments not in QUERIES:
        return 2
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, cancelled)
    try:
        return capture(arguments)
    except BrokenPipeError:
        # The shell reader disappeared after capture. Avoid a second flush.
        with open(os.devnull, "wb") as sink:
            os.dup2(sink.fileno(), sys.stdout.fileno())
        return 1
    except (OSError, ValueError) as error:
        print(f"asusctl {' '.join(arguments)} capture failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
