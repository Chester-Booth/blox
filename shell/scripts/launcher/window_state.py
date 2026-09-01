#!/usr/bin/env python3
"""Persist launcher window positions and close them on outside clicks."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from pathlib import Path

TITLES = {"Blox Clipboard": "clipboard", "Blox Emoji Picker": "emoji"}
PICKER_CLASS = "org.quickshell"
IPC = Path(__file__).resolve().parents[1] / "ipc.sh"
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "blox" / "launcher-window-geometry.json"


def clients() -> list[dict]:
    result = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, check=False)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return []


def cursor_position() -> tuple[int, int] | None:
    result = subprocess.run(["hyprctl", "cursorpos", "-j"], capture_output=True, text=True, check=False)
    try:
        value = json.loads(result.stdout)
        return int(value["x"]), int(value["y"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None


def load() -> dict:
    try:
        value = json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if isinstance(value, dict):
        return value
    return {}


def save(value: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")) + "\n")
    os.replace(temporary, STATE)


def window_position(address: str, desired: tuple[int, int] | None = None) -> tuple[int, int] | None:
    item = next(
        (item for item in clients() if str(item.get("address", "")).removeprefix("0x") == address),
        None,
    )
    result = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True, check=False)
    try:
        monitors = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    monitor = None
    if desired is not None:
        monitor = next(
            (
                value
                for value in monitors
                if int(value.get("x", 0)) <= desired[0] < int(value.get("x", 0)) + int(value.get("width", 0))
                and int(value.get("y", 0)) <= desired[1] < int(value.get("y", 0)) + int(value.get("height", 0))
            ),
            None,
        )
    monitor = monitor or next((value for value in monitors if value.get("focused")), monitors[0] if monitors else None)
    size = item.get("size", []) if item else []
    if not monitor or len(size) != 2:
        return None
    left = int(monitor.get("x", 0))
    top = int(monitor.get("y", 0))
    right = left + int(monitor.get("width", 0)) - int(size[0])
    bottom = top + int(monitor.get("height", 0)) - int(size[1])
    if desired is None:
        desired = right - 20, bottom - 20
    return max(left, min(right, desired[0])), max(top, min(bottom, desired[1]))


def restore(address: str, title: str, state: dict) -> bool:
    geometry = state.get(TITLES[title], {})
    if all(isinstance(geometry.get(key), int) for key in ("x", "y")):
        position = window_position(address, (geometry["x"], geometry["y"]))
    else:
        position = window_position(address)
    if position is None:
        return False
    expression = (
        "hl.dispatch(hl.dsp.window.move({"
        f"x={position[0]},y={position[1]},relative=false,window='address:0x{address}'"
        "}))"
    )
    completed = subprocess.run(
        ["hyprctl", "eval", expression],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        return False
    item = next(
        (item for item in clients() if str(item.get("address", "")).removeprefix("0x") == address),
        None,
    )
    actual = item.get("at", []) if item else []
    return len(actual) == 2 and abs(int(actual[0]) - position[0]) <= 1 and abs(int(actual[1]) - position[1]) <= 1


def mark_positioned(kind: str) -> None:
    subprocess.run(
        [str(IPC), "launcher", "positioned", kind],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def close_picker() -> None:
    subprocess.run(
        [str(IPC), "launcher", "close"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def main() -> int:
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not signature or not runtime:
        return 1
    path = Path(runtime) / "hypr" / signature / ".socket2.sock"
    state = load()
    tracked: dict[str, str] = {}
    restore_until: dict[str, float] = {}
    ready: set[str] = set()
    last_geometry: dict[str, tuple[int, int]] = {}
    last_recovery = 0.0
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(str(path))
    connection.settimeout(0.2)
    buffer = b""
    while True:
        try:
            chunk = connection.recv(65536)
            if not chunk:
                return 0
            buffer += chunk
        except TimeoutError:
            pass
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            event, _, data = raw.decode(errors="replace").partition(">>")
            if event == "openwindow":
                address, _, window_class, title = (data.split(",", 3) + ["", "", "", ""])[:4]
                address = address.removeprefix("0x")
                if window_class == PICKER_CLASS and title in TITLES:
                    tracked[address] = title
                    restore_until[address] = time.monotonic() + 0.65
                    if restore(address, title, state):
                        mark_positioned(TITLES[title])
                        ready.add(address)
            elif event == "closewindow":
                address = data.removeprefix("0x")
                item = next(
                    (item for item in clients() if str(item.get("address", "")).removeprefix("0x") == address),
                    None,
                )
                title = tracked.get(address)
                position = item.get("at", []) if item else list(last_geometry.get(address, ()))
                if title and len(position) == 2 and all(isinstance(value, int) for value in position):
                    state[TITLES[title]] = {"x": position[0], "y": position[1]}
                    save(state)
                tracked.pop(address, None)
                restore_until.pop(address, None)
                ready.discard(address)
                last_geometry.pop(address, None)
            elif event == "custom" and data == "blox-picker-click" and tracked:
                point = cursor_position()
                live = {str(item.get("address", "")).removeprefix("0x"): item for item in clients()}
                inside = False
                if point:
                    for address in tracked:
                        item = live.get(address, {})
                        position = item.get("at", [])
                        size = item.get("size", [])
                        if len(position) == 2 and len(size) == 2 and position[0] <= point[0] < position[0] + size[0] and position[1] <= point[1] < position[1] + size[1]:
                            inside = True
                            break
                if not inside:
                    close_picker()

        now = time.monotonic()
        recovering = now - last_recovery >= 30
        if not tracked and not recovering:
            time.sleep(0.03)
            continue
        if recovering:
            last_recovery = now
        live = {str(item.get("address", "")).removeprefix("0x"): item for item in clients()}
        for address, item in live.items():
            title = str(item.get("title", ""))
            if item.get("class") == PICKER_CLASS and title in TITLES and address not in tracked:
                tracked[address] = title
                restore_until[address] = time.monotonic() + 0.65
        for address in list(tracked):
            if address not in live:
                tracked.pop(address, None)
                restore_until.pop(address, None)
                ready.discard(address)
        changed = False
        for address, title in list(tracked.items()):
            item = live.get(address)
            if not item:
                continue
            if address not in ready:
                if restore(address, title, state) and address not in ready:
                    mark_positioned(TITLES[title])
                    ready.add(address)
                elif time.monotonic() >= restore_until.get(address, 0):
                    # Never leave a failed compositor move as an invisible
                    # input window. The retry window normally succeeds first.
                    mark_positioned(TITLES[title])
                    ready.add(address)
                continue
            position = item.get("at", [])
            if len(position) != 2 or not all(isinstance(value, int) for value in position):
                continue
            geometry = (position[0], position[1])
            if last_geometry.get(address) != geometry:
                last_geometry[address] = geometry
                state[TITLES[title]] = {"x": geometry[0], "y": geometry[1]}
                changed = True
        if changed:
            save(state)
        time.sleep(0.03)


if __name__ == "__main__":
    raise SystemExit(main())
