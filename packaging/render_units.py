#!/usr/bin/env python3
"""Render unit templates into a DESTDIR-style tree for verification."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

PACKAGING_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGING_ROOT))

import layout  # noqa: E402
from install import UNIT_TEMPLATES, product_version, render_unit  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destdir", required=True)
    args = parser.parse_args()

    roots = layout.resolve_roots()
    version = product_version()
    destination = Path(args.destdir) / "systemd" / "user"
    destination.mkdir(parents=True, exist_ok=True)
    for template in UNIT_TEMPLATES:
        unit = destination / template.removesuffix(".in")
        unit.write_text(render_unit(template, roots, version), encoding="utf-8")
        print(unit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
