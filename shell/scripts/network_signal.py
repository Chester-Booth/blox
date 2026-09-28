#!/usr/bin/env python3
"""Print the active NetworkManager Wi-Fi access point's signal strength."""

import json
import subprocess
import sys


SERVICE = "org.freedesktop.NetworkManager"
ROOT = "/org/freedesktop/NetworkManager"
MANAGER = "org.freedesktop.NetworkManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
DEVICE = "org.freedesktop.NetworkManager.Device"
WIRELESS = "org.freedesktop.NetworkManager.Device.Wireless"
ACCESS_POINT = "org.freedesktop.NetworkManager.AccessPoint"


def busctl(*arguments: str):
    result = subprocess.run(
        ["busctl", "--json=short", *arguments],
        check=True,
        capture_output=True,
        text=True,
        timeout=2,
    )
    return json.loads(result.stdout)["data"]


def signal_for_device(interface: str) -> int | None:
    device_paths = busctl("call", SERVICE, ROOT, MANAGER, "GetDevices")[0]
    for device_path in device_paths:
        properties = busctl("call", SERVICE, device_path, PROPERTIES, "GetAll", "s", DEVICE)[0]
        if properties.get("Interface", {}).get("data") != interface:
            continue
        if properties.get("DeviceType", {}).get("data") != 2:
            return None

        access_point = busctl("get-property", SERVICE, device_path, WIRELESS, "ActiveAccessPoint")
        if not access_point or access_point == "/":
            return None

        strength = busctl("get-property", SERVICE, access_point, ACCESS_POINT, "Strength")
        if isinstance(strength, int) and 0 <= strength <= 100:
            return strength
        return None
    return None


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1]:
        return 2
    try:
        signal = signal_for_device(sys.argv[1])
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError):
        return 1
    if signal is None:
        return 1
    print(signal)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
