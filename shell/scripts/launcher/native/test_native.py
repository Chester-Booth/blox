#!/usr/bin/env python3
"""Build the native workers in a temporary directory and run parity tests."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def main() -> int:
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        build = subprocess.run(["/usr/bin/bash", str(ROOT / "build.sh"), str(output)], cwd=ROOT, check=False)
        if build.returncode != 0:
            return build.returncode
        suite = subprocess.run(
            [
                sys.executable,
                str(ROOT / "protocol_suite.py"),
                "--python",
                str(ROOT.parent / "dmenu_server.py"),
                "--rust",
                str(output / "dmenu-server-rust"),
                "--cpp",
                str(output / "dmenu-server-cpp"),
            ],
            cwd=ROOT,
            check=False,
        )
        return suite.returncode


if __name__ == "__main__":
    raise SystemExit(main())
