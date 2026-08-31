#!/usr/bin/env python3
"""Apply and restore the picker's temporary Hyprland preview transaction."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PRODUCT_ROOT = Path(__file__).resolve().parents[3]
THEME_LIB = PRODUCT_ROOT / "themes" / "lib"
if not THEME_LIB.is_dir():
    THEME_LIB = Path(os.environ.get("BLOX_INSTALL_ROOT", Path.home() / ".local/share/blox")) / "themes" / "lib"
sys.path.insert(0, str(THEME_LIB))

from blox_theme.core import apply_theme_defaults, derive_shape, validate_theme  # noqa: E402


OWNED_OPTIONS = (
    "general:border_size",
    "general:gaps_in",
    "general:gaps_out",
    "general:col.active_border",
    "general:col.inactive_border",
    "decoration:rounding",
    "decoration:inactive_opacity",
    "decoration:shadow:color",
)


def state_path() -> Path:
    configured = os.environ.get("BLOX_HYPRLAND_PREVIEW_STATE", "")
    if configured:
        return Path(configured).expanduser()
    return Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "blox-theme-hyprland-preview.json"


def run_hyprctl(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["hyprctl", *arguments], capture_output=True, text=True, check=False)


def config_provider() -> str:
    """Return Hyprland's active config provider, or legacy when unknown."""
    result = run_hyprctl("status", "-j")
    if result.returncode != 0:
        return "legacy"
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return "legacy"
    return str(value.get("configProvider", "legacy")).lower() if isinstance(value, dict) else "legacy"


def gradient_keyword(value: str) -> str:
    parts = value.split()
    converted: list[str] = []
    for part in parts:
        if part.endswith("deg"):
            converted.append(part.removesuffix("deg"))
            continue
        if len(part) == 8 and all(character in "0123456789abcdefABCDEF" for character in part):
            converted.append(f"rgba({part[2:]}{part[:2]})")
        else:
            converted.append(part)
    return " ".join(converted)


def option_keyword_value(option: str, data: dict[str, Any]) -> str:
    if "css" in data:
        return str(data["css"])
    if "int" in data:
        return str(data["int"])
    if "float" in data:
        return format(float(data["float"]), ".6f").rstrip("0").rstrip(".")
    if "gradient" in data:
        return gradient_keyword(str(data["gradient"]))
    raise RuntimeError(f"Hyprland did not return a restorable value for {option}")


def lua_literal(value: str) -> str:
    """Encode a trusted, already-normalised string as a Lua string."""
    return json.dumps(value, ensure_ascii=True)


def lua_number(value: str, option: str) -> str:
    try:
        number = float(value)
    except ValueError as error:
        raise RuntimeError(f"Hyprland returned an invalid numeric value for {option}") from error
    if not number.is_integer():
        return format(number, ".6f").rstrip("0").rstrip(".")
    return str(int(number))


def lua_gap(value: str, option: str) -> str:
    """Convert Hyprland's normalised CSS gap value to a Lua value."""
    parts = value.split()
    if len(parts) == 1:
        return lua_number(parts[0], option)
    if len(parts) != 4:
        raise RuntimeError(f"Hyprland returned an unsupported gap value for {option}")
    top, right, bottom, left = (lua_number(part, option) for part in parts)
    return f"{{ top = {top}, right = {right}, bottom = {bottom}, left = {left} }}"


def lua_colour(value: str, option: str) -> str:
    parts = value.split()
    if not parts or not parts[0].startswith("rgba("):
        raise RuntimeError(f"Hyprland returned an unsupported colour value for {option}")
    return lua_literal(parts[0])


def lua_border(value: str, option: str) -> str:
    """Convert a normalised Hyprland border colour or gradient to Lua."""
    parts = value.split()
    colours = [part for part in parts if part.startswith("rgba(")]
    if not colours:
        raise RuntimeError(f"Hyprland returned an unsupported border value for {option}")
    if len(colours) == 1:
        return lua_literal(colours[0])
    if len(parts) < len(colours) + 1:
        raise RuntimeError(f"Hyprland returned a gradient without an angle for {option}")
    angle = lua_number(parts[-1], option)
    encoded = ", ".join(lua_literal(colour) for colour in colours)
    return f"{{ colors = {{ {encoded} }}, angle = {angle} }}"


def lua_config(values: dict[str, str]) -> str:
    """Build one hl.config call for a Lua-based Hyprland instance."""
    border_size = lua_number(values["general:border_size"], "general:border_size")
    gaps_in = lua_gap(values["general:gaps_in"], "general:gaps_in")
    gaps_out = lua_gap(values["general:gaps_out"], "general:gaps_out")
    active_border = lua_border(values["general:col.active_border"], "general:col.active_border")
    inactive_border = lua_border(values["general:col.inactive_border"], "general:col.inactive_border")
    rounding = lua_number(values["decoration:rounding"], "decoration:rounding")
    opacity = lua_number(values["decoration:inactive_opacity"], "decoration:inactive_opacity")
    shadow = lua_colour(values["decoration:shadow:color"], "decoration:shadow:color")
    return (
        "hl.config({ general = { "
        f"border_size = {border_size}, "
        f"gaps_in = {gaps_in}, gaps_out = {gaps_out}, "
        f"col = {{ active_border = {active_border}, inactive_border = {inactive_border} }} "
        "}, decoration = { "
        f"rounding = {rounding}, inactive_opacity = {opacity}, shadow = {{ color = {shadow} }} "
        "} })"
    )


def hyprctl_succeeded(result: subprocess.CompletedProcess[str]) -> bool:
    if result.returncode != 0:
        return False
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    lines = [line for line in output.splitlines() if line]
    return bool(lines) and all(line == "ok" for line in lines)


def hyprctl_error(result: subprocess.CompletedProcess[str]) -> str:
    return (result.stderr.strip() or result.stdout.strip() or "no detail").replace("\n", " ")


def snapshot() -> dict[str, Any]:
    values: dict[str, str] = {}
    for option in OWNED_OPTIONS:
        result = run_hyprctl("getoption", option, "-j")
        if result.returncode != 0:
            raise RuntimeError(f"could not read Hyprland option {option}: {hyprctl_error(result)}")
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"Hyprland returned invalid data for {option}") from error
        if not isinstance(data, dict) or data.get("set") is not True:
            raise RuntimeError(f"Hyprland option {option} is not set")
        values[option] = option_keyword_value(option, data)
    return {"version": 1, "options": values}


def write_state(value: dict[str, Any]) -> None:
    destination = state_path()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=destination.parent, delete=False) as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.chmod(0o600)
    os.replace(temporary, destination)


def read_state() -> dict[str, Any] | None:
    source = state_path()
    if not source.is_file():
        return None
    try:
        value = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"could not read Hyprland preview state: {source}") from error
    if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("options"), dict):
        raise RuntimeError(f"invalid Hyprland preview state: {source}")
    if set(value["options"]) != set(OWNED_OPTIONS):
        raise RuntimeError(f"Hyprland preview state has the wrong option set: {source}")
    return value


def run_batch(values: dict[str, str]) -> None:
    if config_provider() == "lua":
        result = run_hyprctl("eval", lua_config(values))
    else:
        commands = [f"keyword {option} {values[option]}" for option in OWNED_OPTIONS]
        result = run_hyprctl("--batch", "; ".join(commands))
    if not hyprctl_succeeded(result):
        raise RuntimeError(f"Hyprland preview update failed: {hyprctl_error(result)}")


def rgba(colour: str, alpha: str) -> str:
    return f"rgba({colour.removeprefix('#').lower()}{alpha})"


def preview_values(source: dict[str, Any]) -> dict[str, str]:
    theme = apply_theme_defaults(source)
    checked = validate_theme(theme, check_dependencies=False)
    if checked.errors:
        raise RuntimeError("invalid preview theme: " + "; ".join(checked.errors))
    shape = derive_shape(theme)
    colours = theme["colours"]
    return {
        "general:border_size": str(shape["hyprland_border_size"]),
        "general:gaps_in": str(shape["hyprland_gap"]),
        "general:gaps_out": str(shape["hyprland_gap"]),
        "general:col.active_border": rgba(colours["accent"], "ee"),
        "general:col.inactive_border": rgba(colours["border"], "aa"),
        "decoration:rounding": str(shape["hyprland_rounding"]),
        "decoration:inactive_opacity": format(float(shape["hyprland_inactive_opacity"]), ".2f"),
        "decoration:shadow:color": rgba(colours["background"], "ee"),
    }


def restore() -> None:
    state = read_state()
    if state is None:
        return
    run_batch({key: str(value) for key, value in state["options"].items()})
    state_path().unlink(missing_ok=True)


def apply(source: dict[str, Any]) -> None:
    state = read_state()
    if state is None:
        state = snapshot()
        write_state(state)
    try:
        run_batch(preview_values(source))
    except Exception as error:
        try:
            restore()
        except Exception as restore_error:
            raise RuntimeError(f"{error}; restore also failed: {restore_error}") from restore_error
        raise


def main(arguments: list[str]) -> int:
    if not arguments or arguments[0] not in {"apply", "restore", "recover"}:
        print("usage: hyprland_preview.py apply <theme-json> | restore | recover", file=sys.stderr)
        return 2
    try:
        if arguments[0] == "apply":
            if len(arguments) != 2:
                raise RuntimeError("apply requires a theme JSON argument")
            source = json.loads(arguments[1])
            if not isinstance(source, dict):
                raise RuntimeError("preview theme must be a JSON object")
            apply(source)
        else:
            restore()
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
