#!/usr/bin/env python3
"""Verify the packaged user units against a throwaway fixture install.

Renders and installs the product into a temporary HOME, then runs
`systemd-analyze --user verify` with that HOME so %h paths resolve inside the
fixture. Nothing on the live machine is touched.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGING_ROOT = Path(__file__).resolve().parent
REPO_ROOT = PACKAGING_ROOT.parent
sys.path.insert(0, str(PACKAGING_ROOT))

import layout  # noqa: E402
from install import UNIT_TEMPLATES, install, render_unit, product_version  # noqa: E402


def main() -> int:
    fixture = Path(tempfile.mkdtemp(prefix="blox-unit-check-"))
    environ = {
        "HOME": str(fixture),
        "XDG_CONFIG_HOME": str(fixture / ".config"),
        "XDG_DATA_HOME": str(fixture / ".local" / "share"),
        "XDG_STATE_HOME": str(fixture / ".local" / "state"),
        "XDG_CACHE_HOME": str(fixture / ".cache"),
        "BLOX_PREFIX": str(fixture / ".local"),
    }
    saved = {key: os.environ.get(key) for key in environ}
    try:
        os.environ.update(environ)
        roots = layout.resolve_roots()
        install(roots)
        rendered = []
        for template in UNIT_TEMPLATES:
            unit = roots.systemd_user / template.removesuffix(".in")
            unit.write_text(render_unit(template, roots, product_version()), encoding="utf-8")
            rendered.append(str(unit))
        completed = subprocess.run(
            ["systemd-analyze", "--user", "verify", *rendered],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0 or completed.stdout.strip():
            print(completed.stdout, end="")
            print(completed.stderr, end="", file=sys.stderr)
            return completed.returncode or 1
        print("unit-check: verified", len(rendered), "units against a fixture install")
        return 0
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(fixture, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
