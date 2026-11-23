"""Activate generated global appearance and verify Hyprland's option readback."""
from __future__ import annotations

import json
import math
import re
import subprocess
import time
from typing import Any

from .core import derive_shape


class HyprlandFailure(RuntimeError):
    pass


COMMAND_TIMEOUT_SECONDS = 3.0


def _command(run_command, command: list[str]):
    try:
        return run_command(command, timeout=COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise HyprlandFailure('Hyprland command timed out: ' + ' '.join(command[1:])) from error


def expected_options(theme: dict[str, Any]) -> dict[str, Any]:
    shape = derive_shape(theme)
    colours = theme['colours']
    return {
        'general:border_size': shape['hyprland_border_size'],
        'general:gaps_in': (shape['hyprland_gap'],) * 4,
        'general:gaps_out': (shape['hyprland_gap'],) * 4,
        'general:col.active_border': 'ee' + colours['accent'][1:].lower(),
        'general:col.inactive_border': 'aa' + colours['border'][1:].lower(),
        'decoration:rounding': shape['hyprland_rounding'],
        'decoration:inactive_opacity': round(shape['hyprland_inactive_opacity'], 2),
        'decoration:shadow:color': 'ee' + colours['background'][1:].lower(),
    }


def _number(value: Any) -> float:
    if isinstance(value, bool):
        raise ValueError('boolean option value')
    number = float(value)
    if not math.isfinite(number):
        raise ValueError('non-finite option value')
    return number


def option_value(option: str, data: dict[str, Any]) -> Any:
    if data.get('set') is not True:
        raise ValueError('option is not set')
    if option in ('general:gaps_in', 'general:gaps_out'):
        parts = str(data['css']).split() if 'css' in data else [data['int']]
        values = tuple(_number(part) for part in parts)
        if len(values) == 1:
            return values * 4
        if len(values) != 4:
            raise ValueError('unsupported gap value')
        return values
    if option in ('general:col.active_border', 'general:col.inactive_border', 'decoration:shadow:color'):
        if 'int' in data:
            return f"{int(data['int']) & 0xffffffff:08x}"
        # getoption reports colours as ARGB, including single-colour gradients.
        parts = str(data['gradient']).lower().split()
        if len(parts) not in (1, 2) or not re.fullmatch(r'[0-9a-f]{8}', parts[0]):
            raise ValueError('expected a single colour')
        if len(parts) == 2 and not re.fullmatch(r'-?[0-9.]+deg', parts[1]):
            raise ValueError('invalid gradient angle')
        return parts[0]
    return _number(data['float'] if option == 'decoration:inactive_opacity' else data['int'])


def activate(theme: dict[str, Any], run_command, *, attempts: int = 20) -> None:
    """Reload after publication, then wait briefly for the generated globals."""
    result = _command(run_command, ['hyprctl', 'reload'])
    if result.returncode or result.stdout.strip() != 'ok':
        raise HyprlandFailure('Hyprland reload was not acknowledged')
    result = _command(run_command, ['hyprctl', 'configerrors'])
    if result.returncode or result.stdout.strip() not in ('', 'no flags were set'):
        raise HyprlandFailure('Hyprland reported configuration errors after theme reload')
    expected = expected_options(theme)
    mismatches = []
    for attempt in range(attempts):
        mismatches = []
        for option, wanted in expected.items():
            result = _command(run_command, ['hyprctl', 'getoption', option, '-j'])
            try:
                if result.returncode:
                    raise ValueError('getoption failed')
                actual = option_value(option, json.loads(result.stdout))
                matches = math.isclose(actual, wanted, abs_tol=0.000001) if isinstance(wanted, (int, float)) else actual == wanted
                if not matches:
                    mismatches.append(option)
            except (ValueError, TypeError, KeyError, AttributeError):
                mismatches.append(option)
        if not mismatches:
            return
        if attempt + 1 < attempts:
            time.sleep(0.05)
    raise HyprlandFailure('Hyprland did not load generated appearance: ' + ', '.join(mismatches)
                          + '. Check the generated theme include and later global overrides.')
