#!/usr/bin/env python3
"""Measure the three equal dmenu workers on one host and workload."""

from __future__ import annotations

import argparse
import json
import os
import select
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REQUESTS = 30
REPETITIONS = 15


def read_line(stream, timeout: float = 2.0) -> dict:
    ready, _, _ = select.select([stream], [], [], timeout)
    if not ready:
        raise RuntimeError("worker output timed out")
    line = stream.readline()
    if not line:
        raise RuntimeError("worker exited before output")
    return json.loads(line)


def read_socket_line(client: socket.socket) -> dict:
    client.settimeout(2)
    payload = bytearray()
    while b"\n" not in payload:
        chunk = client.recv(4096)
        if not chunk:
            raise RuntimeError("worker closed the socket")
        payload.extend(chunk)
    return json.loads(bytes(payload).split(b"\n", 1)[0])


def proc_stat(pid: int) -> tuple[float, int]:
    try:
        status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8")
        rss = next((int(line.split()[1]) for line in status.splitlines() if line.startswith("VmRSS:")), 0)
        fields = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()
        cpu_ticks = int(fields[13]) + int(fields[14])
        return float(rss), cpu_ticks
    except (OSError, IndexError, ValueError):
        return 0.0, 0


def wait_for_socket(path: Path) -> None:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.002)
    raise RuntimeError("worker did not create its socket")


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
            wait_for_socket(socket_path)
            starts.append((time.perf_counter() - started) * 1000)
            before = proc_stat(process.pid)
            time.sleep(0.05)
            after = proc_stat(process.pid)
            rss_values.append(after[0])
            cpu_values.append(max(0, after[1] - before[1]) * 1000 / os.sysconf(os.sysconf_names["SC_CLK_TCK"]))

            batch_start = time.perf_counter()
            for index in range(REQUESTS):
                client = socket.socket(socket.AF_UNIX)
                client.connect(str(socket_path))
                request = {"version": 1, "options": ["one", "two"], "prompt": "Pick", "query": "", "fast": False}
                request_start = time.perf_counter()
                client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
                read_line(process.stdout)
                assert process.stdin is not None
                process.stdin.write(b'{"value":"two","cancelled":false}\n')
                process.stdin.flush()
                response = read_socket_line(client)
                client.close()
                if response.get("ok") is not True:
                    raise RuntimeError("worker returned a failed response")
                latencies.append((time.perf_counter() - request_start) * 1000)
            throughput.append(REQUESTS / (time.perf_counter() - batch_start))
            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=2)

    ordered = sorted(latencies)
    return {
        "repetitions": repetitions,
        "requests_per_repetition": REQUESTS,
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
        "p95": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 4),
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
        "workload": {"repetitions": args.repetitions, "requests_per_repetition": REQUESTS, "idle_sample_seconds": 0.05},
        "host": {"python": tool_version([sys.executable, "--version"]), "rustc": tool_version(["rustc", "--version"]), "g++": tool_version(["g++", "--version"])},
        "workers": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({name: {key: value for key, value in data.items() if key != "raw"} for name, data in results.items()}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
