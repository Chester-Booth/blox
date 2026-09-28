#!/usr/bin/env python3
"""Print the active NetworkManager Wi-Fi access point's SSID and signal."""

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


def status_for_device(interface: str) -> dict[str, int | str] | None:
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
        ssid_bytes = busctl("get-property", SERVICE, access_point, ACCESS_POINT, "Ssid")
        if not isinstance(strength, int) or not 0 <= strength <= 100:
            return None
        valid_ssid = isinstance(ssid_bytes, list) and all(
            isinstance(byte, int) and 0 <= byte <= 255 for byte in ssid_bytes
        )
        if not valid_ssid:
            return None
        return {
            "signal": strength,
            "ssid": bytes(ssid_bytes).decode("utf-8", errors="replace"),
        }
    return None


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1]:
        return 2
    try:
        status = status_for_device(sys.argv[1])
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError, TypeError):
        return 1
    if status is None:
        return 1
    print(json.dumps(status, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
