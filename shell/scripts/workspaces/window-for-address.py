#!/usr/bin/env python3
import json
import subprocess
import sys


def normalize(address):
    value = (address or "").strip()
    if not value:
        return ""

    return value if value.startswith("0x") else "0x" + value


target = normalize(sys.argv[1] if len(sys.argv) > 1 else "")
if not target:
    print("{}")
    sys.exit(0)

try:
    raw = subprocess.check_output(["hyprctl", "clients", "-j"], text=True, stderr=subprocess.DEVNULL)
    clients = json.loads(raw)
except Exception:
    print("{}")
    sys.exit(0)

for client in clients:
    address = normalize(client.get("address", ""))
    if address.lower() != target.lower():
        continue

    workspace = client.get("workspace") or {}
    print(json.dumps({
        "address": address,
        "workspace": workspace.get("id"),
        "class": client.get("class") or client.get("initialClass") or "",
        "title": client.get("title") or "",
    }))
    sys.exit(0)

print("{}")
