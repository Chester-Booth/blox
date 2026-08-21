"""Shared path ownership for the installed product.

Every root follows ADR-002: package data is read-only, user config and data
belong to the user, generated state, cache and runtime files belong to the
Blox runtime. Unset XDG variables resolve to the standard locations.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _xdg(name: str, default: Path) -> Path:
    value = os.environ.get(name)
    return Path(value).expanduser() if value else default


@dataclass(frozen=True)
class Roots:
    home: Path
    prefix: Path
    pkg_root: Path
    config: Path
    data: Path
    state: Path
    cache: Path
    runtime: Path
    systemd_user: Path

    @property
    def bins(self) -> Path:
        return self.prefix / "bin"

    @property
    def backups(self) -> Path:
        return self.state / "backups"

    @property
    def generations(self) -> Path:
        return self.state / "generations.json"

    @property
    def migrations_ledger(self) -> Path:
        return self.state / "migrations.jsonl"

    @property
    def manifest(self) -> Path:
        return self.pkg_root / "manifest.json"

    @property
    def previous_pkg_root(self) -> Path:
        return self.pkg_root.parent / "blox.previous"


def resolve_roots() -> Roots:
    home = Path.home()
    prefix = Path(os.environ.get("BLOX_PREFIX", str(home / ".local"))).expanduser()
    config_home = _xdg("XDG_CONFIG_HOME", home / ".config")
    data_home = _xdg("XDG_DATA_HOME", home / ".local" / "share")
    state_home = _xdg("XDG_STATE_HOME", home / ".local" / "state")
    cache_home = _xdg("XDG_CACHE_HOME", home / ".cache")
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or str(state_home / "runtime")
    return Roots(
        home=home,
        prefix=prefix,
        pkg_root=prefix / "share" / "blox",
        config=config_home / "blox",
        data=data_home / "blox",
        state=state_home / "blox",
        cache=cache_home / "blox",
        runtime=Path(runtime_dir) / "blox",
        systemd_user=config_home / "systemd" / "user",
    )
