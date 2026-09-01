#!/usr/bin/env python3
"""Hygiene gates: no personal names, no checkout paths, no secrets."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

PATTERNS = {
    "personal-name": re.compile(r"\bchester\b", re.IGNORECASE),
    "checkout-path": re.compile(r"/home/blox\b|/home/chester\b|Code/personal/dotfiles"),
    "private-key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}

def tracked_files() -> list[Path]:
    completed = subprocess.run(["git", "-C", str(REPO_ROOT), "ls-files"], capture_output=True, text=True, check=True)
    files = [REPO_ROOT / line for line in completed.stdout.splitlines() if line]
    # The scanner's own patterns would match themselves.
    return [path for path in files if path != Path(__file__).resolve()]


def main() -> int:
    failures: list[str] = []
    for path in tracked_files():
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for name, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                context = text[max(0, match.start() - 40):match.end() + 40].replace("\n", " ")
                failures.append(f"{name}: {path.relative_to(REPO_ROOT)}: ...{context}...")
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("hygiene: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
