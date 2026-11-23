"""Report the pointer and focused window position for the Settings shelf."""

import json
import subprocess


def hyprctl_json(command):
    result = subprocess.run(
        ["hyprctl", command, "-j"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


try:
    pointer = hyprctl_json("cursorpos")
    window = hyprctl_json("activewindow")
    result = {
        "x": pointer["x"],
        "y": pointer["y"],
        "originX": window["at"][0],
        "originY": window["at"][1],
        "title": window.get("title", ""),
    }
except (OSError, subprocess.SubprocessError, json.JSONDecodeError, KeyError, TypeError):
    result = {"x": -1, "y": -1, "originX": 0, "originY": 0, "title": ""}

print(json.dumps(result))
