#!/usr/bin/env python3
"""Lean benchmark runner for Blox CI and live desktop checks.

Measures Blox-controlled hot paths without mutating the running shell:
- blox_theme load and validation latency
- blox_widgets schema/profile validation latency
- bloxd native Rust status subcommands (system, workspaces, brightness, touchpad, night-light)
- optional live shell snapshot (anon RSS, file cache, daemon list, idle CPU delta, and child forks)
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

REPO_ROOT = Path(__file__).resolve().parents[1]
BLOXD = REPO_ROOT / "shell/native/qml/Blox/Services/bloxd"


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return round(ordered[index], 3)


def bench_theme_load(iterations: int) -> dict[str, float]:
    """Measure built-in theme load and validation time in milliseconds."""
    sys.path.insert(0, str(REPO_ROOT / "themes/lib"))
    os.environ.setdefault("BLOX_DATA_DIR", str(REPO_ROOT / "themes"))
    from blox_theme.core import load_theme

    load_theme("catppuccin-frappe")
    samples: list[float] = []
    for _ in range(iterations):
        start = time.perf_counter()
        load_theme("catppuccin-frappe")
        samples.append((time.perf_counter() - start) * 1000.0)
    return {
        "iterations": iterations,
        "median_ms": round(statistics.median(samples), 3),
        "p95_ms": _percentile(samples, 0.95),
    }


def bench_widget_validation(iterations: int) -> dict[str, float]:
    """Measure widget profile validation latency in milliseconds."""
    sys.path.insert(0, str(REPO_ROOT / "widgets/lib"))
    from blox_widgets.model import default_profile, validate_profile

    sample = default_profile()
    validate_profile(sample)
    samples: list[float] = []
    for _ in range(iterations):
        start = time.perf_counter()
        validate_profile(sample)
        samples.append((time.perf_counter() - start) * 1000.0)
    return {
        "iterations": iterations,
        "median_ms": round(statistics.median(samples), 3),
        "p95_ms": _percentile(samples, 0.95),
    }


def bench_bloxd(iterations: int) -> dict[str, object]:
    """Measure bloxd Rust status subcommand latency in milliseconds."""
    if not (BLOXD.is_file() and os.access(BLOXD, os.X_OK)):
        return {"available": False}
    results: dict[str, object] = {"available": True}
    count = min(iterations, 15)
    for domain in ("brightness", "touchpad", "night-light", "workspaces"):
        samples: list[float] = []
        for _ in range(count):
            start = time.perf_counter()
            subprocess.run([str(BLOXD), "status", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            samples.append((time.perf_counter() - start) * 1000.0)
        results[domain] = {
            "iterations": count,
            "median_ms": round(statistics.median(samples), 3),
            "p95_ms": _percentile(samples, 0.95),
        }
    return results


def _cgroup_dir() -> Path | None:
    uid = os.getuid()
    path = Path(f"/sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service/app.slice/quickshell.service")
    return path if path.is_dir() else None


def _read_cgroup_stats(cg: Path) -> dict[str, int]:
    out: dict[str, int] = {}
    mem_stat = cg / "memory.stat"
    if mem_stat.is_file():
        for line in mem_stat.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                out[parts[0]] = int(parts[1])
    return out


def _cgroup_pids(cg: Path) -> list[int]:
    procs = cg / "cgroup.procs"
    if not procs.is_file():
        return []
    return [int(line) for line in procs.read_text(encoding="utf-8").splitlines() if line.strip().isdigit()]


def live_shell_snapshot(sample_seconds: float = 0.0) -> dict[str, object]:
    """Read current quickshell.service memory, processes, and optional idle CPU/fork delta."""
    try:
        out = subprocess.check_output(
            [
                "systemctl", "--user", "show", "quickshell.service",
                "-p", "ActiveState", "-p", "MainPID", "-p", "MemoryCurrent",
                "-p", "TasksCurrent", "-p", "CPUUsageNSec", "-p", "NRestarts",
            ],
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"available": False, "error": str(exc)}
    fields = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    mem_bytes = int(fields["MemoryCurrent"]) if fields.get("MemoryCurrent", "").isdigit() else None
    cpu_ns = int(fields["CPUUsageNSec"]) if fields.get("CPUUsageNSec", "").isdigit() else None

    snapshot: dict[str, object] = {
        "available": True,
        "active_state": fields.get("ActiveState", ""),
        "main_pid": int(fields["MainPID"]) if fields.get("MainPID", "").isdigit() else None,
        "tasks": int(fields["TasksCurrent"]) if fields.get("TasksCurrent", "").isdigit() else None,
        "memory_mib": round(mem_bytes / (1024 * 1024), 1) if mem_bytes is not None else None,
        "cpu_seconds": round(cpu_ns / 1e9, 2) if cpu_ns is not None else None,
        "restarts": int(fields["NRestarts"]) if fields.get("NRestarts", "").isdigit() else None,
    }

    cg = _cgroup_dir()
    if cg is not None:
        mstat = _read_cgroup_stats(cg)
        if "anon" in mstat:
            snapshot["anon_mib"] = round(mstat["anon"] / (1024 * 1024), 1)
        if "file" in mstat:
            snapshot["file_cache_mib"] = round(mstat["file"] / (1024 * 1024), 1)
        pids = _cgroup_pids(cg)
        procs: list[str] = []
        for pid in pids:
            try:
                cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
                procs.append(cmd or Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip())
            except OSError:
                continue
        snapshot["process_count"] = len(procs)
        snapshot["processes"] = procs

        if sample_seconds > 0 and cpu_ns is not None:
            initial_pids = set(pids)
            seen_new: set[int] = set()
            deadline = time.monotonic() + sample_seconds
            while time.monotonic() < deadline:
                for pid in _cgroup_pids(cg):
                    if pid not in initial_pids:
                        seen_new.add(pid)
                time.sleep(0.05)
            out2 = subprocess.check_output(
                ["systemctl", "--user", "show", "quickshell.service", "-p", "CPUUsageNSec"],
                text=True,
                timeout=5,
            )
            fields2 = dict(line.split("=", 1) for line in out2.splitlines() if "=" in line)
            cpu_ns2 = int(fields2["CPUUsageNSec"]) if fields2.get("CPUUsageNSec", "").isdigit() else cpu_ns
            delta_s = max(0.0, (cpu_ns2 - cpu_ns) / 1e9)
            snapshot["idle_sample"] = {
                "window_seconds": sample_seconds,
                "cpu_pct": round((delta_s / sample_seconds) * 100.0, 2),
                "new_pids_observed": len(seen_new),
            }
    return snapshot


def run(iterations: int = 30, include_live: bool = False, sample_seconds: float = 0.0) -> dict[str, object]:
    """Run all selected benchmarks and return a JSON-serialisable report."""
    report: dict[str, object] = {
        "theme_load": bench_theme_load(iterations),
        "widget_validation": bench_widget_validation(iterations),
        "bloxd": bench_bloxd(iterations),
    }
    if include_live:
        report["live_shell"] = live_shell_snapshot(sample_seconds=sample_seconds)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--live", action="store_true", help="Include live quickshell.service stats")
    parser.add_argument("--sample-seconds", type=float, default=0.0, help="Idle CPU/fork sample window in seconds")
    parser.add_argument("--output", type=Path, default=None, help="Optional JSON output path")
    args = parser.parse_args(argv)
    report = run(iterations=max(1, args.iterations), include_live=args.live, sample_seconds=max(0.0, args.sample_seconds))
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
