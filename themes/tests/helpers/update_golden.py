#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


THEMES = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(THEMES / "lib"))

from blox_theme.core import load_theme, render_theme


def main() -> None:
    _, theme = load_theme("catppuccin-mocha")
    files, _ = render_theme(theme)
    hashes = {
        name: hashlib.sha256(content.replace(str(THEMES), "<themes>").encode()).hexdigest()
        for name, content in files.items()
    }
    destination = THEMES / "tests/golden/catppuccin-mocha.sha256.json"
    destination.write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
