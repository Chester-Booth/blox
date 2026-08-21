from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .core import DEFAULT_THEME_ID, contrast_ratio, load_theme


MAPPING_VERSION = 1
BACKENDS = ("matugen", "pywal")
MATUGEN_SCHEMES = (
    "scheme-content",
    "scheme-expressive",
    "scheme-fidelity",
    "scheme-fruit-salad",
    "scheme-monochrome",
    "scheme-neutral",
    "scheme-rainbow",
    "scheme-tonal-spot",
    "scheme-vibrant",
)


class GeneratorFailure(RuntimeError):
    pass


def wallpaper_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _colour(value: Any, field: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
        raise GeneratorFailure(f"generator output has invalid colour at {field}")
    return value.lower()


def _matugen_value(payload: dict[str, Any], name: str, mode: str) -> str:
    try:
        value = payload["colors"][name][mode]["color"]
    except (KeyError, TypeError) as error:
        raise GeneratorFailure(f"matugen output is missing colors.{name}.{mode}.color") from error
    return _colour(value, f"colors.{name}.{mode}.color")


def map_matugen(payload: dict[str, Any], mode: str) -> dict[str, str]:
    get = lambda name: _matugen_value(payload, name, mode)
    return {
        "background": get("background"),
        "surface": get("surface_container"),
        "surface_alt": get("surface_container_high"),
        "foreground": get("on_surface"),
        "muted": get("on_surface_variant"),
        "accent": get("primary"),
        "danger": get("error"),
        "success": get("tertiary"),
        "warning": get("secondary"),
        "info": get("primary"),
        "mauve": get("secondary"),
        "teal": get("tertiary"),
        "selection_background": get("primary"),
        "selection_foreground": get("on_primary"),
        "border": get("outline"),
    }


def _higher_contrast(first: str, second: str, background: str) -> str:
    return max((first, second), key=lambda value: (contrast_ratio(value, background), value))


def map_pywal(payload: dict[str, Any], mode: str) -> dict[str, str]:
    try:
        special = payload["special"]
        raw = payload["colors"]
    except (KeyError, TypeError) as error:
        raise GeneratorFailure("pywal output must contain special and colors objects") from error
    colours = {f"color{index}": _colour(raw.get(f"color{index}"), f"colors.color{index}") for index in range(16)}
    background = _colour(special.get("background"), "special.background")
    foreground = _colour(special.get("foreground"), "special.foreground")
    role = lambda normal, bright: _higher_contrast(colours[f"color{normal}"], colours[f"color{bright}"], background)
    accent = role(4, 12)
    if contrast_ratio(accent, background) < 3:
        accent = max((accent, role(5, 13), role(6, 14)), key=lambda value: (contrast_ratio(value, background), value))
    selection_background = accent
    selection_foreground = _higher_contrast(background, foreground, selection_background)
    if contrast_ratio(selection_foreground, selection_background) < 4.5:
        selection_background = foreground
        selection_foreground = background
    return {
        "background": background,
        "surface": colours["color0"],
        "surface_alt": colours["color8"],
        "foreground": foreground,
        "muted": colours["color8"],
        "accent": accent,
        "danger": role(1, 9),
        "success": role(2, 10),
        "warning": role(3, 11),
        "info": accent,
        "mauve": role(5, 13),
        "teal": role(6, 14),
        "selection_background": selection_background,
        "selection_foreground": selection_foreground,
        "border": colours["color8"],
    }


def contrast_report(colours: dict[str, str]) -> list[dict[str, Any]]:
    pairs = (
        ("foreground", "background", 4.5),
        ("foreground", "surface", 4.5),
        ("muted", "background", 4.5),
        ("selection_foreground", "selection_background", 4.5),
        ("accent", "background", 3.0),
    )
    return [
        {
            "foreground": foreground,
            "background": background,
            "ratio": round(contrast_ratio(colours[foreground], colours[background]), 2),
            "minimum": minimum,
            "ok": contrast_ratio(colours[foreground], colours[background]) >= minimum,
        }
        for foreground, background, minimum in pairs
    ]


def _sandbox_environment(root: Path) -> dict[str, str]:
    home = root / "home"
    cache = root / "cache"
    config = root / "config"
    data = root / "data"
    for path in (home, cache, config, data):
        path.mkdir()
    environment = {
        "HOME": str(home),
        "XDG_CACHE_HOME": str(cache),
        "XDG_CONFIG_HOME": str(config),
        "XDG_DATA_HOME": str(data),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    return environment


def _version(executable: str, backend: str) -> str:
    flag = "--version" if backend == "matugen" else "-v"
    completed = subprocess.run([executable, flag], capture_output=True, text=True, check=False, timeout=10)
    if completed.returncode:
        raise GeneratorFailure(f"could not determine {backend} version")
    output = (completed.stdout or completed.stderr).strip()
    match = re.search(r"\d+(?:\.\d+)+", output)
    if not match:
        raise GeneratorFailure(f"could not parse {backend} version: {output!r}")
    return match.group(0)


def _run(command: list[str], environment: dict[str, str], backend: str) -> subprocess.CompletedProcess[str]:
    try:
        completed = subprocess.run(command, env=environment, capture_output=True, text=True, check=False, timeout=60)
    except subprocess.TimeoutExpired as error:
        raise GeneratorFailure(f"{backend} timed out after 60 seconds") from error
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit status {completed.returncode}"
        raise GeneratorFailure(f"{backend} failed: {detail}")
    return completed


def _load_output(value: str, backend: str) -> dict[str, Any]:
    try:
        payload = json.loads(value)
    except json.JSONDecodeError as error:
        raise GeneratorFailure(f"{backend} produced invalid JSON: {error}") from error
    if not isinstance(payload, dict):
        raise GeneratorFailure(f"{backend} output root must be an object")
    return payload


def generate_theme(
    wallpaper: Path,
    backend: str = "matugen",
    mode: str = "dark",
    scheme: str = "scheme-tonal-spot",
    contrast: float = 0.0,
    source_colour_index: int = 0,
    saturation: float | None = None,
    theme_id: str | None = None,
    name: str | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if backend not in BACKENDS:
        if backend == "wallust":
            raise GeneratorFailure("wallust is intentionally disabled in Phase 4")
        raise GeneratorFailure(f"unsupported generator backend: {backend}")
    if mode not in ("dark", "light"):
        raise GeneratorFailure(f"unsupported generator mode: {mode}")
    if backend == "matugen":
        if saturation is not None:
            raise GeneratorFailure("--saturate is only valid with the pywal backend")
        if scheme not in MATUGEN_SCHEMES:
            raise GeneratorFailure(f"unsupported matugen scheme: {scheme}")
        if not -1 <= contrast <= 1:
            raise GeneratorFailure("matugen contrast must be between -1 and 1")
        if not 0 <= source_colour_index <= 3:
            raise GeneratorFailure("matugen 4.1 source colour index must be between 0 and 3")
    else:
        if scheme != "scheme-tonal-spot" or contrast != 0 or source_colour_index != 0:
            raise GeneratorFailure("matugen scheme, contrast, and source colour options are not valid with pywal")
        if saturation is not None and not 0 <= saturation <= 1:
            raise GeneratorFailure("pywal saturation must be between 0 and 1")
    source = wallpaper.expanduser().resolve()
    if not source.exists():
        raise FileNotFoundError(f"wallpaper does not exist: {source}")
    if not source.is_file():
        raise GeneratorFailure(f"wallpaper is not a regular file: {source}")
    executable = shutil.which("wal" if backend == "pywal" else backend)
    if not executable:
        raise FileNotFoundError(f"generator backend is not installed: {backend}")
    version = _version(executable, backend)

    with tempfile.TemporaryDirectory(prefix=f"themectl-{backend}-") as temporary:
        root = Path(temporary)
        environment = _sandbox_environment(root)
        if backend == "matugen":
            command = [
                executable, "image", str(source), "--type", scheme, "--mode", mode,
                "--contrast", str(contrast), "--source-color-index", str(source_colour_index),
                "--json", "hex", "--dry-run", "--quiet",
            ]
            payload = _load_output(_run(command, environment, backend).stdout, backend)
            colours = map_matugen(payload, mode)
            options: dict[str, Any] = {
                "mode": mode,
                "scheme": scheme,
                "contrast": contrast,
                "source_colour_index": source_colour_index,
            }
        else:
            command = [executable, "-n", "-s", "-t", "-e", "-q", "-i", str(source)]
            if mode == "light":
                command.insert(1, "-l")
            if saturation is not None:
                command[1:1] = ["--saturate", str(saturation)]
            _run(command, environment, backend)
            output_path = Path(environment["HOME"]) / ".cache/wal/colors.json"
            if not output_path.is_file():
                raise GeneratorFailure("pywal did not produce colors.json in its isolated cache")
            payload = _load_output(output_path.read_text(encoding="utf-8"), backend)
            colours = map_pywal(payload, mode)
            options = {"mode": mode}
            if saturation is not None:
                options["saturation"] = saturation

    _, base = load_theme(DEFAULT_THEME_ID)
    theme = copy.deepcopy(base)
    theme.pop("overrides", None)
    stem = re.sub(r"[^a-z0-9]+", "-", source.stem.casefold()).strip("-") or "wallpaper"
    generated_id = f"{stem}-{backend}"[:64].rstrip("-")
    theme.update(
        id=theme_id or generated_id,
        name=name or f"{source.stem} ({backend})"[:80],
        variant=mode,
        colours=colours,
        wallpaper={"path": str(source), "fit": base["wallpaper"]["fit"]},
        generator={
            "backend": backend,
            "version": version,
            "mapping_version": MAPPING_VERSION,
            "options": options,
            "wallpaper_sha256": wallpaper_digest(source),
        },
    )
    theme["cursor"].update(
        base_colour=colours["accent"],
        outline_colour=colours["selection_foreground"],
        watch_background=colours["background"],
    )
    theme["terminal"].update(canvas=colours["background"], chrome_background=colours["background"])
    return theme, contrast_report(colours)


def save_theme_source(theme: dict[str, Any], directory: Path, replace: bool = False, expected_sha256: str | None = None) -> Path:
    theme_id = theme.get("id")
    if not isinstance(theme_id, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", theme_id):
        raise GeneratorFailure("theme id is not safe for a source filename")
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / f"{theme_id}.json"
    if replace:
        if not destination.is_file() or destination.is_symlink():
            raise GeneratorFailure(f"theme source is not a regular file: {destination}")
        if not expected_sha256 or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
            raise GeneratorFailure("replacement requires a valid expected source digest")
        actual = hashlib.sha256(destination.read_bytes()).hexdigest()
        if actual != expected_sha256:
            raise GeneratorFailure("theme source changed since it was loaded; refresh before replacing it")
    elif expected_sha256 is not None:
        raise GeneratorFailure("expected source digest is only valid with replacement")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{theme_id}-", suffix=".json", dir=directory)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(theme, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if replace:
            os.replace(temporary, destination)
        else:
            try:
                os.link(temporary, destination)
            except FileExistsError as error:
                raise GeneratorFailure(f"theme source already exists: {destination}") from error
        directory_descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        temporary.unlink(missing_ok=True)
    return destination
