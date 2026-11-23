#!/usr/bin/env python3
"""Private startup replay of the current generation, without changing selection."""
from __future__ import annotations
import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from shell.scripts import bloxctl
from themes.lib.blox_theme import runtime


def run(targets=None):
    preview = Path(os.environ.get("BLOX_HYPRLAND_PREVIEW_STATE") or
                   str(Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "blox-theme-hyprland-preview.json"))
    if os.path.lexists(preview):
        return bloxctl.result(False, "conflict", "Startup replay is blocked by a retained preview.")
    status = bloxctl._apply_backend("status")
    if not status["ok"] or status["data"] is not None:
        return bloxctl.result(False, "conflict", "Startup replay is blocked by retained Apply state.", status["data"])
    try:
        manifest, warnings = runtime.reconcile(targets)
        return bloxctl.result(True, "ok", data={"generation": manifest["generation_id"], "warnings": warnings})
    except runtime.LockContended as error:
        return bloxctl.result(False, "busy", str(error))
    except (OSError, runtime.RuntimeFailure, ValueError) as error:
        return bloxctl.result(False, "failed", str(error))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", choices=("cursor",))
    args = parser.parse_args()
    response = run((args.targets,) if args.targets else None)
    print(json.dumps(response))
    return bloxctl.exit_code(response)


if __name__ == "__main__":
    raise SystemExit(main())
