"""Browser target metadata and installed-application probes."""

from __future__ import annotations

import os
import shlex
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


@dataclass(frozen=True)
class BrowserTarget:
    id: str
    label: str
    executable_names: tuple[str, ...]
    desktop_entry_names: tuple[str, ...]
    generated_files: tuple[str, ...]
    restart_guidance: str


BROWSER_TARGETS = (
    BrowserTarget(
        id="helium",
        label="Helium",
        executable_names=("helium-browser", "helium"),
        desktop_entry_names=("helium.desktop", "helium-browser.desktop"),
        generated_files=("helium/manifest.json",),
        restart_guidance="Helium must be restarted to read the generated theme",
    ),
    BrowserTarget(
        id="chromium",
        label="Chromium",
        executable_names=("chromium", "chromium-browser"),
        desktop_entry_names=("chromium.desktop", "chromium-browser.desktop"),
        generated_files=("chromium/manifest.json",),
        restart_guidance="Chromium must be restarted to read the generated theme",
    ),
)
BROWSER_TARGET_BY_ID = {target.id: target for target in BROWSER_TARGETS}


def browser_target(target_id: str) -> BrowserTarget:
    try:
        return BROWSER_TARGET_BY_ID[target_id]
    except KeyError as error:
        raise ValueError(f"unsupported browser target: {target_id}") from error


def desktop_entry_dirs() -> tuple[Path, ...]:
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()
    data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
    directories = [data_home / "applications"]
    directories.extend(Path(value).expanduser() / "applications" for value in data_dirs if value)
    return tuple(dict.fromkeys(directories))


def _desktop_exec(path: Path) -> str | None:
    section = ""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        value = line.strip()
        if value.startswith("[") and value.endswith("]"):
            section = value[1:-1]
            continue
        if section == "Desktop Entry" and value.startswith("Exec="):
            try:
                command = shlex.split(value.removeprefix("Exec="), posix=True)
            except ValueError:
                return None
            return command[0] if command else None
    return None


def _path_key(path: Path) -> str:
    try:
        return str(path.resolve())
    except OSError:
        return str(path)


def _default_is_executable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def _resolve_executable(
    token: str,
    which: Callable[[str], str | None],
    is_executable: Callable[[Path], bool],
) -> Path | None:
    candidate = Path(token).expanduser()
    if candidate.is_absolute():
        return candidate if is_executable(candidate) else None
    located = which(token)
    if not located:
        return None
    path = Path(located).expanduser()
    return path if is_executable(path) else None


def _base_result(target: BrowserTarget) -> dict:
    return {
        "target": target.id,
        "label": target.label,
        "supported": True,
        "installed": False,
        "available": False,
        "probe": None,
        "executable": None,
        "desktop_entry": None,
        "matches": [],
        "reason": "",
    }


def detect_browser_target(
    target_id: str,
    *,
    which: Callable[[str], str | None] | None = None,
    desktop_dirs: Iterable[Path] | None = None,
    is_executable: Callable[[Path], bool] | None = None,
) -> dict:
    """Return structured availability for one browser target.

    A desktop entry only counts when its Exec field resolves to a known,
    executable browser binary. Blox's own launcher therefore cannot make a
    missing browser install look available.
    """
    target = browser_target(target_id)
    which = which or shutil.which
    is_executable = is_executable or _default_is_executable
    result = _base_result(target)
    candidates: dict[str, dict] = {}
    desktop_paths: list[Path] = []
    rejected_executables: list[str] = []

    for name in target.executable_names:
        located = which(name)
        if located and not is_executable(Path(located).expanduser()):
            rejected_executables.append(name)
            continue
        path = _resolve_executable(name, which, is_executable)
        if path is None:
            continue
        key = _path_key(path)
        candidates.setdefault(key, {"kind": "executable", "name": name, "path": str(path)})

    directories = tuple(desktop_dirs) if desktop_dirs is not None else desktop_entry_dirs()
    for directory in directories:
        for entry_name in target.desktop_entry_names:
            path = directory / entry_name
            if not path.is_file():
                continue
            token = _desktop_exec(path)
            if token is None:
                continue
            # The managed desktop entry points at Blox's wrapper. It must not
            # make an absent system browser look installed.
            if Path(token).name == f"blox-{target.id}-browser":
                continue
            desktop_paths.append(path)
            if Path(token).name not in target.executable_names:
                continue
            executable = _resolve_executable(token, which, is_executable)
            if executable is None:
                continue
            key = _path_key(executable)
            candidates.setdefault(key, {"kind": "desktop-entry", "name": entry_name, "path": str(executable), "desktop_entry": str(path)})
            if "desktop_entry" not in candidates[key]:
                candidates[key]["desktop_entry"] = str(path)

    if len(candidates) > 1:
        result["matches"] = list(candidates.values())
        result["reason"] = f"ambiguous browser installation: more than one {target.label} executable matched"
        return result

    if not candidates:
        if desktop_paths:
            result["reason"] = f"stale or unsupported {target.label} desktop entry; no executable browser matched"
        elif rejected_executables:
            result["reason"] = f"{target.label} executable is not executable"
        else:
            result["reason"] = f"{target.label} is not installed"
        return result

    matches = list(candidates.values())
    match = matches[0]
    result.update({
        "installed": True,
        "available": True,
        "probe": {key: match[key] for key in ("kind", "name", "path")},
        "executable": match["path"],
        "desktop_entry": match.get("desktop_entry"),
        "matches": matches,
    })
    return result


def detect_browser_targets(**kwargs: object) -> list[dict]:
    return [detect_browser_target(target.id, **kwargs) for target in BROWSER_TARGETS]
