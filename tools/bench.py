#!/usr/bin/env python3
"""Lean benchmark runner for Blox CI and local checks.

Measures Blox-controlled hot paths without modifying the running shell:
- blox_theme load and validation latency
- blox_widgets schema/profile validation latency
- optional live shell snapshot (CPU/RSS/process count of quickshell.service)
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


def live_shell_snapshot() -> dict[str, object]:
    """Read current quickshell.service memory and task count from systemd."""
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
    return {
        "available": True,
        "active_state": fields.get("ActiveState", ""),
        "main_pid": int(fields["MainPID"]) if fields.get("MainPID", "").isdigit() else None,
        "tasks": int(fields["TasksCurrent"]) if fields.get("TasksCurrent", "").isdigit() else None,
        "memory_mib": round(mem_bytes / (1024 * 1024), 1) if mem_bytes is not None else None,
        "cpu_seconds": round(cpu_ns / 1e9, 2) if cpu_ns is not None else None,
        "restarts": int(fields["NRestarts"]) if fields.get("NRestarts", "").isdigit() else None,
    }


def run(iterations: int = 30, include_live: bool = False) -> dict[str, object]:
    """Run all selected benchmarks and return a JSON-serialisable report."""
    report: dict[str, object] = {
        "theme_load": bench_theme_load(iterations),
        "widget_validation": bench_widget_validation(iterations),
    }
    if include_live:
        report["live_shell"] = live_shell_snapshot()
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--live", action="store_true", help="Include live quickshell.service stats")
    parser.add_argument("--output", type=Path, default=None, help="Optional JSON output path")
    args = parser.parse_args(argv)
    report = run(iterations=max(1, args.iterations), include_live=args.live)
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
