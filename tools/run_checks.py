#!/usr/bin/env python3
"""Parallel test and lint runner backing `make check` and `make ci`.

Builds native services and widgets once, then fans out independent Make targets
and sharded Python/QML suites across a bounded worker pool. All test lists and
non-sharded recipes stay owned by Makefile so nothing can drift.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

REPO_ROOT = Path(__file__).resolve().parents[1]
NATIVE_IMPORT_ROOT = REPO_ROOT / "shell/native/qml"
WIDGETS_QML_ROOT = REPO_ROOT / "widgets/qml"

# Individual targets that stay single-job because each takes <= 7s and owns its
# own Makefile recipe.
MAKE_TARGETS = [
    "qmllint",
    "py-compile",
    "shellcheck",
    "test-performance",
    "test-image-decode",
    "test-status-contracts",
    "test-bloxctl",
    "test-graphics-control",
    "test-lifecycle",
    "test-doctor",
    "test-cutover",
    "test-qml-paths",
    "test-qml-tokens",
    "test-widgets-qml",
    "validate-status",
    "unit-check",
    "diff-check",
]

# Known slowest QML test files run solo so they never stack behind other files.
HEAVY_QML_TESTS = {
    "tst_SettingsWidgetDataSafety.qml",
    "tst_VolumeOsd.qml",
    "tst_SettingsWidgetCompact.qml",
    "tst_BarSurfaceController.qml",
    "tst_MediaKeyController.qml",
}


@dataclass(frozen=True)
class CheckJob:
    name: str
    commands: tuple[list[str], ...]
    env: dict[str, str]
    priority: int = 10


def base_env() -> dict[str, str]:
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def qmltestrunner_bin() -> str:
    candidate = Path("/usr/lib/qt6/bin/qmltestrunner")
    if candidate.is_file():
        return str(candidate)
    found = shutil.which("qmltestrunner")
    return found or str(candidate)


def build_jobs(include_hygiene: bool, jobs: int) -> list[CheckJob]:
    shared_env = base_env()
    runner = qmltestrunner_bin()
    make_bin = os.environ.get("MAKE", "make")
    work: list[CheckJob] = []

    # 1. Sharded validate-themes (24 files; slowest single file ~16s).
    themes_env = {**shared_env, "TMPDIR": "/tmp", "BLOX_DATA_DIR": str(REPO_ROOT / "themes")}
    theme_files = sorted((REPO_ROOT / "themes/tests").glob("test_*.py"))
    heavy_themes = {"test_runtime.py", "test_apply_owners.py", "test_editor_apply_publication.py", "test_themes.py"}
    for path in theme_files:
        prio = 0 if path.name in heavy_themes else 8
        work.append(CheckJob(
            name=f"themes/{path.stem}",
            commands=([sys.executable, "-m", "unittest", "discover", "-s", "themes/tests", "-p", path.name, "-v"],),
            env=themes_env,
            priority=prio,
        ))

    # 2. Sharded tests/qml (95 files; slowest solo ~10s, remainder batched).
    qml_env = {**shared_env, "QML_XHR_ALLOW_FILE_READ": "1", "QT_QPA_PLATFORM": "offscreen"}
    qml_prefix = [
        runner,
        "-import", str(NATIVE_IMPORT_ROOT),
        "-import", str(WIDGETS_QML_ROOT),
        "-import", "tests/qml/imports",
        "-import", "tests/qml/provider-imports",
        "-input",
    ]
    qml_files = sorted((REPO_ROOT / "tests/qml").glob("tst_*.qml"))
    fast_qml: list[Path] = []
    for path in qml_files:
        if path.name in HEAVY_QML_TESTS:
            work.append(CheckJob(
                name=f"qml/{path.stem}",
                commands=([*qml_prefix, str(path.relative_to(REPO_ROOT))],),
                env=qml_env,
                priority=1,
            ))
        else:
            fast_qml.append(path)
    batch_count = max(1, min(6, jobs))
    batches: list[list[list[str]]] = [[] for _ in range(batch_count)]
    for index, path in enumerate(fast_qml):
        batches[index % batch_count].append([*qml_prefix, str(path.relative_to(REPO_ROOT))])
    for index, batch in enumerate(batches, start=1):
        if batch:
            work.append(CheckJob(
                name=f"qml/batch-{index} ({len(batch)} files)",
                commands=tuple(batch),
                env=qml_env,
                priority=2,
            ))

    work.append(CheckJob(
        name="tests/native-qml",
        commands=([runner, "-import", "tests/qml/imports", "-import", str(NATIVE_IMPORT_ROOT), "-input", "tests/native-qml"],),
        env=qml_env,
        priority=5,
    ))

    # 3. Launcher Python tests (owned by LAUNCHER_PY_TESTS in Makefile).
    launcher_py = os.environ.get("LAUNCHER_PY_TESTS", "").split()
    if launcher_py:
        work.append(CheckJob(
            name="test-launcher-py",
            commands=([sys.executable, "-m", "unittest", *launcher_py, "-v"],),
            env=shared_env,
            priority=6,
        ))

    # 4. Native services tests (owned by NATIVE_SERVICE_TESTS in Makefile).
    native_service_tests = os.environ.get("NATIVE_SERVICE_TESTS", "").split()
    for module in native_service_tests:
        prio = 2 if module.endswith(("image_cache", "service_owner")) else 5
        work.append(CheckJob(
            name=f"native/{module.removeprefix('tests.')}",
            commands=([sys.executable, "-m", "unittest", module, "-v"],),
            env=shared_env,
            priority=prio,
        ))

    # 5. Sharded widgets Python tests + terminal renderer.
    existing_py = shared_env.get("PYTHONPATH", "")
    widgets_py_path = f"{REPO_ROOT / 'widgets/lib'}{':' + existing_py if existing_py else ''}"
    widgets_env = {**shared_env, "BLOX_DATA_DIR": str(REPO_ROOT / "themes"), "PYTHONPATH": widgets_py_path}
    work.append(CheckJob(
        name="widgets/metadata-bootstrap",
        commands=([sys.executable, "-m", "unittest", "tests.test_widget_metadata_bootstrap", "-v"],),
        env=shared_env,
        priority=8,
    ))
    work.append(CheckJob(
        name="widgets/render-terminal",
        commands=([sys.executable, "widgets/tests/render_terminal.py"],),
        env=shared_env,
        priority=7,
    ))
    heavy_widgets = {"test_providers.py", "test_preview.py", "test_mpris_native.py"}
    for path in sorted((REPO_ROOT / "widgets/tests").glob("test_*.py")):
        prio = 1 if path.name in heavy_widgets else 8
        work.append(CheckJob(
            name=f"widgets/{path.stem}",
            commands=([sys.executable, "-m", "unittest", str(path.relative_to(REPO_ROOT)), "-v"],),
            env=widgets_env,
            priority=prio,
        ))

    # 6. All remaining Make targets, delegating straight to Makefile recipes with native builds already done.
    targets = list(MAKE_TARGETS) + (["hygiene"] if include_hygiene else [])
    for target in targets:
        prio = 3 if target in {"qmllint", "test-widgets-qml", "test-lifecycle", "test-bloxctl", "test-image-decode", "validate-status"} else 7
        work.append(CheckJob(
            name=target,
            commands=([make_bin, "--no-print-directory", "BUILD_NATIVE=0", target],),
            env=shared_env,
            priority=prio,
        ))

    # Longest-running jobs start first to minimise tail latency.
    work.sort(key=lambda item: (item.priority, item.name))
    return work


def run_job(job: CheckJob) -> tuple[CheckJob, int, float, str]:
    start = time.monotonic()
    chunks: list[str] = []
    for cmd in job.commands:
        completed = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            env=job.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            chunks.append(f"$ {' '.join(cmd)}\n{completed.stdout}")
            return job, completed.returncode, time.monotonic() - start, "\n".join(chunks)
    return job, 0, time.monotonic() - start, ""


def build_native_prerequisites() -> int:
    make_bin = os.environ.get("MAKE", "make")
    shared_env = base_env()
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [
            pool.submit(
                subprocess.run,
                [make_bin, "--no-print-directory", target],
                cwd=REPO_ROOT,
                env=shared_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            for target in ("native-services", "native-widgets")
        ]
        for future in futures:
            completed = future.result()
            if completed.returncode != 0:
                sys.stderr.write(completed.stdout)
                return completed.returncode
    print(f"native builds ready in {time.monotonic() - start:.2f}s", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Blox checks in parallel.")
    parser.add_argument("--ci", action="store_true", help="Include hygiene gate.")
    parser.add_argument(
        "--jobs",
        type=int,
        default=int(os.environ.get("CHECK_JOBS", str(min(os.cpu_count() or 4, 8)))),
        help="Worker pool size (default: min(nproc, 8)).",
    )
    args = parser.parse_args()
    workers = max(1, args.jobs)

    total_start = time.monotonic()
    rc = build_native_prerequisites()
    if rc != 0:
        return rc

    jobs = build_jobs(include_hygiene=args.ci, jobs=workers)
    failures: list[tuple[CheckJob, int, float, str]] = []
    timings: list[tuple[float, str]] = []

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(run_job, job) for job in jobs]
        for future in as_completed(futures):
            job, code, elapsed, output = future.result()
            timings.append((elapsed, job.name))
            if code != 0:
                failures.append((job, code, elapsed, output))
                print(f"FAIL  {elapsed:5.2f}s  {job.name} (exit {code})", flush=True)
            elif elapsed >= 4.0:
                print(f"ok    {elapsed:5.2f}s  {job.name}", flush=True)

    total = time.monotonic() - total_start
    if failures:
        print(f"\n{len(failures)}/{len(jobs)} check jobs failed in {total:.2f}s:", file=sys.stderr)
        for job, code, elapsed, output in failures:
            print(f"\n=== FAIL: {job.name} (exit {code}, {elapsed:.2f}s) ===", file=sys.stderr)
            sys.stderr.write(output[-12000:])
            if output and not output.endswith("\n"):
                sys.stderr.write("\n")
        return 1

    slowest = ", ".join(f"{name} {dt:.1f}s" for dt, name in sorted(timings, reverse=True)[:4])
    label = "ci" if args.ci else "check"
    print(f"make {label}: {len(jobs)} jobs passed in {total:.2f}s ({workers} workers; slowest: {slowest})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
