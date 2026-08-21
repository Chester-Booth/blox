#!/usr/bin/env python3
import json
import shutil
import subprocess


def hypr_json(*args):
    try:
        out = subprocess.check_output(["hyprctl", *args, "-j"], text=True, stderr=subprocess.DEVNULL)
        return json.loads(out)
    except Exception:
        return None


ICON_RULES = [
    (("t3",), "T3"),
    (("intellij", "idea"), ""),
    (("code",), "󰨞"),
    (("firefox",), "󰈹"),
    (("zen",), ""),
    (("chrome",), ""),
    (("helium",), ""),
    (("zen", "helium", "firefox", "chrome", "brave"), ""),
    (("discord", "vesktop"), ""),
    (("slack",), "󰒱"),
    (("teams",), "󰊻"),
    (("thunar", "dolphin", "nemo", "pcmanfm"), "󰉋"),
    (("obsidian",), "󱞁"),
    (("obs",), "󰕧"),
    (("steam",), "󰓓"),
    (("prism", "minecraft"), "󰍳"),
    (("gimp",), ""),
    (("electron",), ""),
    (("drawing",), "󱇣"),
    (("kitty", "wezterm", "alacritty", "foot"), ""),
]


def app_name(client):
    return client.get("class") or client.get("initialClass") or ""


def icon_match(value):
    app = (value or "").lower()
    for index, (terms, icon) in enumerate(ICON_RULES):
        if any(term in app for term in terms):
            return index, icon
    return len(ICON_RULES), "󰻃"


def icon_for(value):
    return icon_match(value)[1]


def priority_client(clients):
    if not clients:
        return None

    return min(
        clients,
        key=lambda client: (
            icon_match(app_name(client))[0],
            client.get("focusHistoryID", 999999),
        ),
    )


SPECIAL_WORKSPACE = "special:magic"


def workspace_name(workspace):
    return str((workspace or {}).get("name", ""))


def special_workspace_active(active_workspace, monitors):
    if workspace_name(active_workspace) == SPECIAL_WORKSPACE:
        return True

    focused_monitor = next((monitor for monitor in monitors if monitor.get("focused")), None)
    if focused_monitor:
        return workspace_name(focused_monitor.get("specialWorkspace")) == SPECIAL_WORKSPACE

    return any(
        workspace_name(monitor.get("specialWorkspace")) == SPECIAL_WORKSPACE
        for monitor in monitors
    )


active_value = hypr_json("activeworkspace")
clients_value = hypr_json("clients")
monitors_value = hypr_json("monitors")
hypr_available = shutil.which("hyprctl") is not None
hypr_ready = active_value is not None and clients_value is not None and monitors_value is not None
active = active_value or {}
clients = clients_value or []
monitors = monitors_value or []

active_id = active.get("id")
by_workspace = {}
urgent = set()

for client in clients:
    workspace = client.get("workspace") or {}
    workspace_id = workspace.get("id")
    if workspace_id is None:
        continue

    by_workspace.setdefault(workspace_id, []).append(client)
    if client.get("urgent"):
        urgent.add(workspace_id)

workspace_ids = set(range(1, 6))
workspace_ids.update(
    workspace_id
    for workspace_id, workspace_clients in by_workspace.items()
    if workspace_id > 5 and workspace_clients
)

items = []
for workspace_id in sorted(workspace_ids):
    workspace_clients = by_workspace.get(workspace_id, [])
    focused = workspace_id == active_id
    chosen = priority_client(workspace_clients)
    urgent_client = next((client for client in workspace_clients if client.get("urgent")), None)

    app = ""
    title = ""
    if chosen:
        app = app_name(chosen)
        title = chosen.get("title") or ""

    items.append({
        "id": workspace_id,
        "active": focused,
        "urgent": workspace_id in urgent,
        "urgentAddress": urgent_client.get("address", "") if urgent_client else "",
        "empty": len(workspace_clients) == 0,
        "icon": "󰗖" if workspace_id in urgent else (icon_for(app) if chosen else "󰄰"),
        "tooltip": f"Workspace {workspace_id}" + (f"\\n{app}\\n{title}" if app or title else ""),
    })

special_active = special_workspace_active(active, monitors)
special_clients = [
    client for client in clients
    if workspace_name(client.get("workspace")) == SPECIAL_WORKSPACE
]
print(json.dumps({
    "main": items,
    "special": {
        "active": special_active,
        "occupied": len(special_clients) > 0,
        "icon": "󰘻" if special_active else "󰘼",
        "tooltip": "Special workspace" + (f"\\n{len(special_clients)} window(s)" if special_clients else ""),
    },
    "capability": {
        "available": hypr_available,
        "ready": hypr_ready,
        "canChange": False,
        "permission": "not-required",
        "reason": None if hypr_ready else "query-failed" if hypr_available else "command-unavailable",
    },
}))
