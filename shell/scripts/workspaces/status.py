#!/usr/bin/env python3
"""Emit Hyprland workspace status, per-monitor state, and grouped desktop-entry app metadata."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any


def hypr_json(*args: str) -> Any:
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

SPECIAL_WORKSPACE = "special:magic"


def app_name(client: dict[str, Any]) -> str:
    return str(client.get("class") or client.get("initialClass") or "")


def icon_match(value: str) -> tuple[int, str]:
    app = (value or "").lower()
    for index, (terms, icon) in enumerate(ICON_RULES):
        if any(term in app for term in terms):
            return index, icon
    return len(ICON_RULES), "󰻃"


def icon_for(value: str) -> str:
    return icon_match(value)[1]


def desktop_entry_dirs() -> list[Path]:
    """Return XDG application directories without executing anything inside them."""
    dirs: list[Path] = []
    xdg_data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()
    dirs.append(xdg_data_home / "applications")
    dirs.append(xdg_data_home / "flatpak/exports/share/applications")
    for raw in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"):
        if raw:
            dirs.append(Path(raw) / "applications")
    dirs.append(Path("/var/lib/flatpak/exports/share/applications"))
    seen: set[Path] = set()
    unique: list[Path] = []
    for path in dirs:
        if path not in seen and path.is_dir():
            seen.add(path)
            unique.append(path)
    return unique


def _parse_desktop_file(path: Path) -> dict[str, str] | None:
    """Read Name, Icon, and StartupWMClass from the [Desktop Entry] section safely."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    in_entry = False
    entry: dict[str, str] = {"desktopId": path.stem}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("["):
            if in_entry:
                break
            in_entry = stripped == "[Desktop Entry]"
            continue
        if not in_entry or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        if key in ("Name", "Icon", "StartupWMClass", "NoDisplay", "Hidden") and key not in entry:
            entry[key] = value.strip()
    if entry.get("Hidden", "").lower() == "true":
        return None
    return entry


class DesktopEntryResolver:
    """Resolve Hyprland window classes to desktop-entry icons and accessible names."""

    def __init__(self, search_dirs: list[Path] | None = None):
        self._search_dirs = search_dirs if search_dirs is not None else desktop_entry_dirs()
        self._index: dict[str, dict[str, str]] | None = None

    def _build_index(self) -> dict[str, dict[str, str]]:
        index: dict[str, dict[str, str]] = {}
        # Scan in reverse priority so higher-priority XDG dirs overwrite lower ones.
        for directory in reversed(self._search_dirs):
            try:
                files = sorted(directory.glob("*.desktop"))
            except OSError:
                continue
            for path in files:
                parsed = _parse_desktop_file(path)
                if not parsed:
                    continue
                keys = {path.stem.lower()}
                wm_class = parsed.get("StartupWMClass", "").strip().lower()
                if wm_class:
                    keys.add(wm_class)
                # Handle Flatpak reverse-DNS IDs (e.g. org.mozilla.firefox -> firefox).
                if "." in path.stem:
                    keys.add(path.stem.rsplit(".", 1)[-1].lower())
                for key in keys:
                    index[key] = parsed
        return index

    def resolve(self, app_class: str, title: str = "") -> dict[str, str]:
        raw = (app_class or "").strip()
        if not raw:
            return {"desktopId": "", "name": title or "Application", "iconName": ""}
        if self._index is None:
            self._index = self._build_index()
        candidates = [raw.lower()]
        if "." in raw:
            candidates.append(raw.rsplit(".", 1)[-1].lower())
        if "-" in raw:
            candidates.append(raw.split("-", 1)[0].lower())
        for candidate in candidates:
            hit = self._index.get(candidate)
            if hit:
                return {
                    "desktopId": hit.get("desktopId", ""),
                    "name": hit.get("Name") or raw,
                    "iconName": hit.get("Icon", ""),
                }
        return {"desktopId": "", "name": raw, "iconName": ""}


def priority_client(clients: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not clients:
        return None
    return min(
        clients,
        key=lambda client: (
            icon_match(app_name(client))[0],
            client.get("focusHistoryID", 999999),
        ),
    )


def group_workspace_apps(
    clients: list[dict[str, Any]],
    resolver: DesktopEntryResolver,
) -> list[dict[str, Any]]:
    """Group windows in one workspace by application class while preserving focus order."""
    ordered = sorted(
        clients,
        key=lambda client: (
            0 if client.get("urgent") else 1,
            icon_match(app_name(client))[0],
            client.get("focusHistoryID", 999999),
        ),
    )
    groups: dict[str, dict[str, Any]] = {}
    for client in ordered:
        cls = app_name(client)
        key = (cls or client.get("title") or "window").lower()
        info = resolver.resolve(cls, str(client.get("title") or ""))
        group = groups.get(key)
        if group is None:
            group = {
                "appClass": cls,
                "desktopId": info["desktopId"],
                "name": info["name"],
                "iconName": info["iconName"],
                "glyph": icon_for(cls),
                "count": 0,
                "urgent": False,
                "addresses": [],
            }
            groups[key] = group
        group["count"] += 1
        if client.get("urgent"):
            group["urgent"] = True
        address = str(client.get("address") or "")
        if address:
            group["addresses"].append(address)
    return list(groups.values())


def workspace_name(workspace: dict[str, Any] | None) -> str:
    return str((workspace or {}).get("name", ""))


def special_workspace_active(active_workspace: dict[str, Any], monitors: list[dict[str, Any]]) -> bool:
    if workspace_name(active_workspace) == SPECIAL_WORKSPACE:
        return True
    focused_monitor = next((monitor for monitor in monitors if monitor.get("focused")), None)
    if focused_monitor:
        return workspace_name(focused_monitor.get("specialWorkspace")) == SPECIAL_WORKSPACE
    return any(
        workspace_name(monitor.get("specialWorkspace")) == SPECIAL_WORKSPACE
        for monitor in monitors
    )


def build_status(
    active_value: Any,
    clients_value: Any,
    monitors_value: Any,
    workspaces_value: Any = None,
    *,
    hypr_available: bool = True,
    resolver: DesktopEntryResolver | None = None,
) -> dict[str, Any]:
    """Assemble typed workspace, per-monitor fullscreen, and grouped app state."""
    hypr_ready = active_value is not None and clients_value is not None and monitors_value is not None
    active = active_value or {}
    clients = clients_value or []
    monitors = monitors_value or []
    workspaces = workspaces_value if isinstance(workspaces_value, list) else []
    app_resolver = resolver or DesktopEntryResolver()

    active_id = active.get("id")
    ws_meta: dict[int, dict[str, Any]] = {}
    for ws in workspaces:
        if isinstance(ws, dict) and isinstance(ws.get("id"), int):
            ws_meta[ws["id"]] = ws

    monitor_active_ids: dict[str, int] = {}
    monitor_summary: dict[str, dict[str, Any]] = {}
    default_monitor = ""
    for monitor in monitors:
        if not isinstance(monitor, dict) or monitor.get("disabled") is True:
            continue
        m_name = str(monitor.get("name", ""))
        if not default_monitor:
            default_monitor = m_name
        active_ws = monitor.get("activeWorkspace") if isinstance(monitor.get("activeWorkspace"), dict) else {}
        m_active_id = active_ws.get("id")
        if isinstance(m_active_id, int):
            monitor_active_ids[m_name] = m_active_id
        meta = ws_meta.get(m_active_id, {}) if isinstance(m_active_id, int) else {}
        monitor_summary[m_name] = {
            "activeWorkspaceId": m_active_id,
            "focused": bool(monitor.get("focused", False)),
            "hasFullscreen": bool(meta.get("hasfullscreen", False)),
        }

    by_workspace: dict[int, list[dict[str, Any]]] = {}
    urgent: set[int] = set()
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
    for m_active_id in monitor_active_ids.values():
        if isinstance(m_active_id, int) and m_active_id > 0:
            workspace_ids.add(m_active_id)

    items = []
    for workspace_id in sorted(workspace_ids):
        workspace_clients = by_workspace.get(workspace_id, [])
        focused = workspace_id == active_id
        meta = ws_meta.get(workspace_id, {})
        owner_monitor = str(meta.get("monitor") or "")
        if not owner_monitor:
            owner_monitor = next(
                (m_name for m_name, mid in monitor_active_ids.items() if mid == workspace_id),
                default_monitor,
            )
        active_on_monitor = bool(owner_monitor and monitor_active_ids.get(owner_monitor) == workspace_id)
        chosen = priority_client(workspace_clients)
        urgent_client = next((client for client in workspace_clients if client.get("urgent")), None)
        apps = group_workspace_apps(workspace_clients, app_resolver)

        app = app_name(chosen) if chosen else ""
        title = (chosen.get("title") or "") if chosen else ""

        items.append({
            "id": workspace_id,
            "monitor": owner_monitor,
            "active": focused,
            "activeOnMonitor": active_on_monitor,
            "hasFullscreen": bool(meta.get("hasfullscreen", False)),
            "urgent": workspace_id in urgent,
            "urgentAddress": urgent_client.get("address", "") if urgent_client else "",
            "empty": len(workspace_clients) == 0,
            "windowCount": len(workspace_clients),
            "apps": apps,
            "icon": "󰗖" if workspace_id in urgent else (icon_for(app) if chosen else "󰄰"),
            "tooltip": f"Workspace {workspace_id}" + (f"\n{app}\n{title}" if app or title else ""),
        })

    special_active = special_workspace_active(active, monitors)
    special_clients = [
        client for client in clients
        if workspace_name(client.get("workspace")) == SPECIAL_WORKSPACE
    ]
    return {
        "main": items,
        "monitors": monitor_summary,
        "special": {
            "active": special_active,
            "occupied": len(special_clients) > 0,
            "icon": "󰘻" if special_active else "󰘼",
            "tooltip": "Special workspace" + (f"\n{len(special_clients)} window(s)" if special_clients else ""),
        },
        "capability": {
            "available": hypr_available,
            "ready": hypr_ready,
            "canChange": False,
            "permission": "not-required",
            "reason": None if hypr_ready else "query-failed" if hypr_available else "command-unavailable",
        },
    }


def main() -> int:
    payload = build_status(
        hypr_json("activeworkspace"),
        hypr_json("clients"),
        hypr_json("monitors"),
        hypr_json("workspaces"),
        hypr_available=shutil.which("hyprctl") is not None,
    )
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
