"""Shared runtime constants, exceptions, and atomic filesystem helpers."""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import uuid
from pathlib import Path

from .core import EDITOR_THEME_PACKAGE_NAME, EDITOR_THEME_PUBLISHER, EDITOR_THEME_VERSION


TARGET_FILES = {
    "quickshell": ("quickshell/theme.json",),
    "widgets": ("widgets/profile.json",),
    "kitty": ("kitty/theme.conf",),
    "wallpaper": ("hypr/wallpaper.json",),
    "gtk": ("gtk/gtk-3.0/settings.ini", "gtk/gtk-3.0/gtk.css", "gtk/gtk-4.0/settings.ini", "gtk/gtk-4.0/gtk.css", "gtk/metadata.json"),
    "helium": ("helium/manifest.json",),
    "chromium": ("chromium/manifest.json",),
    "cursor": ("cursor/metadata.json",),
    "hyprland": ("hyprland/theme.lua", "hyprland/hyprtoolkit.conf"),
    "hyprlock": ("hyprlock/theme.conf",),
    "btop": ("btop/theme.theme",),
    "micro": ("micro/blox-theme.micro",),
    "glow": ("glow/style.json",),
    "code": ("code/settings.json", "code/package.json", "code/themes/blox-generated-color-theme.json"),
    "cursor_editor": ("cursor-editor/settings.json", "cursor-editor/package.json", "cursor-editor/themes/blox-generated-color-theme.json"),
    "t3code": ("t3code/theme.json",),
    "zed": ("zed/themes/blox-generated.json",),
    "stylus": ("stylus/blox-system.user.css", "stylus/manifest.json"),
    "obsidian": ("obsidian/manifest.json", "obsidian/theme.css"),
    "powerlevel10k": ("powerlevel10k/theme.zsh",),
}
TARGET_REQUIRED_FILES = {
    **{target: files for target, files in TARGET_FILES.items() if target != "gtk"},
    "gtk": ("gtk/gtk-3.0/settings.ini", "gtk/gtk-4.0/settings.ini", "gtk/metadata.json"),
}
# The GTK-owned Helium path is accepted only while an old generation is being
# carried forward. New generations never copy it.
LEGACY_TARGET_FILES = {
    "obsidian/blox-theme.css": "obsidian",
    "obsidian/style-settings.json": "obsidian",
    "gtk/helium/manifest.json": "gtk",
    "code/themes/blox-dark-2026.json": "code",
}
# Chromium writes this cache beside an unpacked theme extension at startup.
RUNTIME_ARTIFACTS = {"helium/Cached Theme.pak", "chromium/Cached Theme.pak"}
TARGET_NAMES = tuple(TARGET_FILES)
GENERATION_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
HISTORY_LIMIT = 5
PHASE7_FALLBACK_TARGETS = ("hyprlock", "btop", "micro", "glow")
EDITOR_SETTING_KEYS = {
    "code": ("workbench.colorTheme", "editor.fontFamily", "workbench.experimental.modernUI"),
    "cursor_editor": ("workbench.colorTheme", "editor.fontFamily"),
}
EDITOR_MODERN_UI_SUPPORT = {"code": True, "cursor_editor": False}
EDITOR_LEGACY_EXTENSION_DIR = "blox.blox-dark-2026-1.0.0"
EDITOR_EXTENSION_DIR = f"{EDITOR_THEME_PUBLISHER}.{EDITOR_THEME_PACKAGE_NAME}-{EDITOR_THEME_VERSION}"
T3CODE_THEME_ID = "blox-theme"
ZED_THEME_WATCH_SETTLE_SECONDS = 0.2


class RuntimeFailure(Exception):
    """A safe, user-facing runtime failure."""


class ObsidianPublicationConflict(RuntimeFailure):
    """Publication cleanup preserved a newer Obsidian selection."""


class _ObsidianConflictWarning(str):
    """Keep the conflict classification through the existing reload warnings."""


class LockContended(RuntimeFailure):
    """Another mutating theme operation owns the application lock."""


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())


def _atomic_write_text(path: Path, content: str) -> None:
    """Replace a text file without exposing a partial document to its watcher."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        _write_text(temporary, content)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()




def _run(command: list[str], *, timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    try:
        environment = None
        if command and Path(command[0]).name == "obsidian":
            # The shell can export this for Electron-based tools. Obsidian's
            # wrapper interprets it as a request to run as plain Node and then
            # fails before it reaches the official CLI.
            environment = os.environ.copy()
            environment.pop("ELECTRON_RUN_AS_NODE", None)
        return subprocess.run(command, check=False, capture_output=True, text=True, env=environment, timeout=timeout)
    except OSError as error:
        return subprocess.CompletedProcess(command, 127, "", str(error))


