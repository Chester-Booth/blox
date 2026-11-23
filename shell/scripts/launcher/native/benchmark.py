#!/usr/bin/env python3
"""Measure the three equal dmenu workers on one host and workload."""

from __future__ import annotations

import argparse
import json
import math
import os
import select
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REQUESTS = 500
WARMUP_REQUESTS = 20
REPETITIONS = 15
MAX_REPLY_BYTES = 64 * 1024


def read_line(stream, timeout: float = 2.0) -> dict:
    """Read one bounded reply within a total deadline, including partial lines."""
    deadline = time.monotonic() + timeout
    payload = bytearray()
    while b"\n" not in payload:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise RuntimeError("worker output timed out")
        chunk = os.read(stream.fileno(), 4096)
        if not chunk:
            raise RuntimeError("worker exited before a complete reply")
        payload.extend(chunk)
        if len(payload) > MAX_REPLY_BYTES:
            raise RuntimeError("worker reply exceeds its bound")
    line, trailing = bytes(payload).split(b"\n", 1)
    if trailing:
        raise RuntimeError("worker returned unsolicited output")
    return json.loads(line)


def read_socket_line(client: socket.socket) -> dict:
    return read_line(client)


def proc_stat(pid: int) -> tuple[float, int]:
    try:
        status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
        rss = next(int(line.split()[1]) for line in status.splitlines() if line.startswith("VmRSS:"))
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        # comm may contain spaces or closing parentheses. CPU fields follow it.
        closing = raw.rfind(")")
        if closing < 0 or int(raw.split("(", 1)[0]) != pid:
            raise ValueError("invalid process identity")
        fields = raw[closing + 2:].split()
        ticks = (int(fields[11]), int(fields[12]))
        if rss <= 0 or any(value < 0 for value in ticks):
            raise ValueError("invalid process counters")
        cpu_ticks = sum(ticks)
        return float(rss), cpu_ticks
    except (OSError, IndexError, ValueError, StopIteration) as error:
        raise RuntimeError("worker resource counters are unavailable or invalid") from error


def wait_for_socket(path: Path) -> None:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.002)
    raise RuntimeError("worker did not create its socket")


def stop_worker(process: subprocess.Popen) -> None:
    """Stop a worker left running by a failed sample and close its pipes."""
    try:
        if process.poll() is None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                process.wait(timeout=1)
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass


def run_worker(command: list[str], binary: Path, repetitions: int) -> dict:
    starts: list[float] = []
    latencies: list[float] = []
    throughput: list[float] = []
    rss_values: list[float] = []
    cpu_values: list[float] = []
    for _ in range(repetitions):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            socket_path = runtime / "blox-launcher/dmenu.sock"
            environment = {**os.environ, "XDG_RUNTIME_DIR": str(runtime)}
            started = time.perf_counter()
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            try:
                wait_for_socket(socket_path)
                starts.append((time.perf_counter() - started) * 1000)
                before = proc_stat(process.pid)
                time.sleep(0.05)
                after = proc_stat(process.pid)
                rss_values.append(after[0])
                if after[1] < before[1]:
                    raise RuntimeError("worker CPU counter moved backwards")
                cpu_values.append((after[1] - before[1]) * 1000 / os.sysconf(os.sysconf_names["SC_CLK_TCK"]))

                batch_start = None
                for index in range(WARMUP_REQUESTS + REQUESTS):
                    if index == WARMUP_REQUESTS:
                        batch_start = time.perf_counter()
                    client = socket.socket(socket.AF_UNIX)
                    try:
                        client.connect(str(socket_path))
                        request = {"version": 1, "options": ["one", "two"], "prompt": "Pick", "query": "", "fast": False}
                        request_start = time.perf_counter()
                        client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
                        event = read_line(process.stdout)
                        if (not isinstance(event, dict) or type(event.get("version")) is not int
                                or type(event.get("fast")) is not bool
                                or event != {"event": "request", **request}):
                            raise RuntimeError("worker did not deliver the requested workload")
                        assert process.stdin is not None
                        process.stdin.write(b'{"value":"two","cancelled":false}\n')
                        process.stdin.flush()
                        response = read_socket_line(client)
                    finally:
                        client.close()
                    if (not isinstance(response, dict) or type(response.get("version")) is not int
                            or response.get("ok") is not True
                            or response != {"version": 1, "ok": True, "value": "two"}):
                        raise RuntimeError("worker returned an incorrect selection")
                    if index >= WARMUP_REQUESTS:
                        latencies.append((time.perf_counter() - request_start) * 1000)
                assert batch_start is not None
                throughput.append(REQUESTS / (time.perf_counter() - batch_start))
                assert process.stdin is not None
                process.stdin.close()
                exit_code = process.wait(timeout=2)
                if exit_code != 0:
                    raise RuntimeError(f"{binary.name} worker exited with status {exit_code}")
            finally:
                stop_worker(process)

    return {
        "repetitions": repetitions,
        "requests_per_repetition": REQUESTS,
        "warmup_requests_per_repetition": WARMUP_REQUESTS,
        "binary_bytes": binary.stat().st_size,
        "start_ms": summarise(starts),
        "request_latency_ms": summarise(latencies),
        "idle_rss_kb": summarise(rss_values),
        "idle_cpu_ms_50ms": summarise(cpu_values),
        "throughput_requests_per_s": summarise(throughput),
        "raw": {"start_ms": starts, "request_latency_ms": latencies, "idle_rss_kb": rss_values, "idle_cpu_ms_50ms": cpu_values, "throughput_requests_per_s": throughput},
    }


def summarise(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    return {
        "median": round(statistics.median(values), 4),
        "p95": round(ordered[math.ceil(len(ordered) * 0.95) - 1], 4),
        "min": round(min(values), 4),
        "max": round(max(values), 4),
    }


def tool_version(command: list[str]) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        return (result.stdout or result.stderr).strip().splitlines()[0]
    except (OSError, IndexError):
        return "unavailable"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--rust", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=REPETITIONS)
    args = parser.parse_args()
    workers = {
        "python": ([sys.executable, str(args.python)], args.python),
        "rust": ([str(args.rust)], args.rust),
        "cpp": ([str(args.cpp)], args.cpp),
    }
    results = {}
    for name, (command, binary) in workers.items():
        results[name] = run_worker(command, binary, args.repetitions)
    document = {
        "schema_version": 1,
        "workload": {
            "repetitions": args.repetitions,
            "requests_per_repetition": REQUESTS,
            "warmup_requests_per_repetition": WARMUP_REQUESTS,
            "idle_sample_seconds": 0.05,
        },
        "host": {"python": tool_version([sys.executable, "--version"]), "rustc": tool_version(["rustc", "--version"]), "g++": tool_version(["g++", "--version"])},
        "workers": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({name: {key: value for key, value in data.items() if key != "raw"} for name, data in results.items()}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
