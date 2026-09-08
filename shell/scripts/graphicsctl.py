#!/usr/bin/env python3
"""Typed monitor and GPU control adapter used by the Quickshell owners."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable


TIMEOUT_SECONDS = 5
STANDARD_MODES = ("dedicated", "hybrid", "integrated")
MODE_LABELS = {mode: mode.title() for mode in STANDARD_MODES}
SUPERGFX_MODES = {
    "dedicated": ("AsusMuxDgpu", "Dedicated"),
    "hybrid": ("Hybrid",),
    "integrated": ("Integrated",),
}
COMPETING_SERVICES = (
    "optimus-manager.service",
    "system76-power.service",
    "gpu-eco-boot.service",
    "nvidia-exec.service",
)
GPU_VENDORS = {"1002": "amd", "10de": "nvidia", "8086": "intel"}
PCI_DISPLAY_RE = re.compile(
    r"pci (?P<address>[0-9a-fA-F:.]+): \[(?P<vendor>[0-9a-fA-F]{4}):[0-9a-fA-F]{4}\]"
    r".* class 0x03[0-9a-fA-F]{4}"
)


class AdapterError(Exception):
    def __init__(self, code: str, message: str, data: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def capability(available: bool, ready: bool, can_change: bool, permission: str, reason: str | None) -> dict[str, Any]:
    return {
        "available": available,
        "ready": ready,
        "canChange": can_change,
        "permission": permission,
        "reason": reason,
    }


def action(ok: bool, code: str, message: str = "", data: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"version": 1, "ok": ok, "code": code, "message": message, "data": data}


def launch_detached(command: list[str]) -> None:
    try:
        subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as error:
        raise AdapterError("unavailable", "the logout command could not be started") from error


def run_controller_then_logout(
    command: list[str],
    logout_command: list[str],
    popen_factory: Callable[..., Any] = subprocess.Popen,
    logout_launcher: Callable[[list[str]], None] = launch_detached,
    settle: Callable[[float], None] = time.sleep,
) -> subprocess.CompletedProcess[str]:
    try:
        process = popen_factory(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as error:
        raise AdapterError("unavailable", f"{command[0]} is unavailable") from error
    settle(0.75)
    if process.poll() is not None:
        stdout, stderr = process.communicate()
        completed = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        if completed.returncode == 0:
            logout_launcher(logout_command)
        return completed
    logout_launcher(logout_command)
    try:
        stdout, stderr = process.communicate(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        process.terminate()
        process.communicate()
        raise AdapterError("timeout", f"{command[0]} timed out after logout started") from error
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def run_command(command: list[str], timeout: int = TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise AdapterError("timeout", f"{command[0]} timed out") from error
    except OSError as error:
        raise AdapterError("unavailable", f"{command[0]} is unavailable") from error


def parse_mode(value: str) -> tuple[int, int, float] | None:
    match = re.fullmatch(r"(\d+)x(\d+)@(\d+(?:\.\d+)?)Hz", value)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), float(match.group(3))


def rate_id(rate: float) -> str:
    return f"{rate:.3f}".rstrip("0").rstrip(".")


def monitor_snapshot(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, list):
        raise AdapterError("invalid-data", "Hyprland returned a non-array monitor snapshot")
    monitors = []
    for item in raw:
        if not isinstance(item, dict) or item.get("disabled") is True or item.get("dpmsStatus") is False:
            continue
        try:
            name = str(item["name"])
            width = int(item["width"])
            height = int(item["height"])
            current_rate = float(item["refreshRate"])
            x = int(item["x"])
            y = int(item["y"])
            scale = float(item["scale"])
            transform = int(item["transform"])
        except (KeyError, TypeError, ValueError) as error:
            raise AdapterError("invalid-data", "Hyprland returned an invalid active monitor") from error
        rates: dict[str, float] = {}
        for advertised in item.get("availableModes", []):
            parsed = parse_mode(str(advertised))
            if parsed and parsed[:2] == (width, height):
                rates[rate_id(parsed[2])] = parsed[2]
        if not rates:
            rates[rate_id(current_rate)] = current_rate
        choices = [
            {"id": key, "rate": value, "label": f"{value:g} Hz"}
            for key, value in sorted(rates.items(), key=lambda pair: pair[1], reverse=True)
        ]
        current_choice = min(choices, key=lambda choice: abs(choice["rate"] - current_rate))
        monitors.append({
            "name": name,
            "description": str(item.get("description", name)),
            "width": width,
            "height": height,
            "refreshRate": current_rate,
            "refreshId": current_choice["id"],
            "x": x,
            "y": y,
            "scale": scale,
            "transform": transform,
            "rates": choices,
            "canChange": len(choices) > 1,
        })
    can_change = any(item["canChange"] for item in monitors)
    reason = None if can_change else "no-refresh-choice"
    if not monitors:
        reason = "no-active-monitor"
    return {
        "schemaVersion": 1,
        "monitors": monitors,
        "monitorCount": len(monitors),
        "capability": capability(True, True, can_change, "not-required", reason),
    }


def query_monitors(runner: Callable[..., subprocess.CompletedProcess[str]] = run_command) -> dict[str, Any]:
    completed = runner(["hyprctl", "-j", "monitors"])
    if completed.returncode != 0:
        raise AdapterError("unavailable", "Hyprland monitor discovery failed")
    try:
        raw = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise AdapterError("invalid-data", "Hyprland returned malformed monitor data") from error
    return monitor_snapshot(raw)


def matching_monitor(snapshot: dict[str, Any], name: str) -> dict[str, Any] | None:
    return next((item for item in snapshot["monitors"] if item["name"] == name), None)


def same_geometry(current: dict[str, Any], expected: dict[str, Any]) -> bool:
    fields = ("width", "height", "x", "y", "scale", "transform")
    return all(current.get(field) == expected.get(field) for field in fields)


def monitor_eval(monitor: dict[str, Any], rate: float) -> str:
    scale = rate_id(float(monitor["scale"]))
    refresh = rate_id(rate)
    return (
        "hl.monitor({ "
        f'output = {json.dumps(monitor["name"])}, '
        f'mode = "{monitor["width"]}x{monitor["height"]}@{refresh}", '
        f'position = "{monitor["x"]}x{monitor["y"]}", '
        f'scale = {scale}, transform = {monitor["transform"]} '
        "})"
    )


def set_refresh(name: str, requested_id: str, expected: dict[str, Any], runner: Callable[..., subprocess.CompletedProcess[str]] = run_command) -> dict[str, Any]:
    before = query_monitors(runner)
    monitor = matching_monitor(before, name)
    if monitor is None:
        raise AdapterError("stale", "the selected monitor is no longer active")
    expected_rate = float(expected.get("refreshRate", -1))
    if not same_geometry(monitor, expected) or abs(float(monitor["refreshRate"]) - expected_rate) > 0.05:
        raise AdapterError("stale", "the monitor changed before the refresh request")
    choice = next((item for item in monitor["rates"] if item["id"] == requested_id), None)
    if choice is None:
        raise AdapterError("invalid-data", "the requested refresh rate is unavailable")
    if requested_id == monitor["refreshId"]:
        return action(True, "ok", data={"monitor": name, "refreshId": requested_id, "changed": False, "rollback": "not-needed"})

    result = runner(["hyprctl", "eval", monitor_eval(monitor, choice["rate"])])
    if result.returncode != 0:
        raise AdapterError("failed", "Hyprland rejected the refresh request", {"failedStep": "apply", "rollback": "not-needed"})
    after = query_monitors(runner)
    observed = matching_monitor(after, name)
    if observed and same_geometry(observed, monitor) and abs(float(observed["refreshRate"]) - float(choice["rate"])) <= 0.05:
        return action(True, "ok", data={"monitor": name, "refreshId": requested_id, "changed": True, "rollback": "not-needed"})

    rollback = runner(["hyprctl", "eval", monitor_eval(monitor, monitor["refreshRate"])])
    rollback_state = "applied" if rollback.returncode == 0 else "failed"
    raise AdapterError("failed", "the refresh change could not be verified", {"failedStep": "verify", "rollback": rollback_state})


def drm_devices(root: Path | None = None) -> list[dict[str, Any]]:
    drm_root = root or Path(os.environ.get("BLOX_DRM_ROOT", "/sys/class/drm"))
    devices = []
    for vendor_file in sorted(drm_root.glob("card*/device/vendor")):
        card = vendor_file.parents[1].name
        vendor_id = vendor_file.read_text(encoding="utf-8").strip().lower().removeprefix("0x")
        vendor = GPU_VENDORS.get(vendor_id, "other")
        boot_file = vendor_file.parent / "boot_vga"
        boot_vga = boot_file.is_file() and boot_file.read_text(encoding="utf-8").strip() == "1"
        driver_link = vendor_file.parent / "driver"
        try:
            driver = driver_link.resolve(strict=True).name
        except OSError:
            driver = "unknown"
        kind = "integrated" if boot_vga else "discrete"
        device_path = vendor_file.parent.resolve()
        pci_address = device_path.name if re.fullmatch(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]", device_path.name) else ""
        devices.append({
            "id": card,
            "pciAddress": pci_address,
            "vendor": vendor,
            "driver": driver,
            "kind": kind,
            "bootVga": boot_vga,
            "present": True,
        })
    return devices


def boot_display_devices(runner: Callable[..., subprocess.CompletedProcess[str]] = run_command) -> list[dict[str, Any]]:
    """Read display devices enumerated this boot, including devices later powered off."""
    completed = runner([
        "journalctl", "-b", "-k", "--no-pager", "--grep",
        r"pci [0-9a-fA-F:.]+: \[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\].* class 0x03",
    ])
    if completed.returncode != 0:
        return []
    found: dict[str, dict[str, Any]] = {}
    for line in completed.stdout.splitlines():
        match = PCI_DISPLAY_RE.search(line)
        if not match:
            continue
        address = match.group("address").lower()
        vendor = GPU_VENDORS.get(match.group("vendor").lower(), "other")
        found[address] = {
            "id": f"pci:{address}",
            "pciAddress": address,
            "vendor": vendor,
            "driver": "unbound",
            "kind": "discrete",
            "bootVga": False,
            "present": False,
        }
    return list(found.values())


def discover_gpu_devices(runner: Callable[..., subprocess.CompletedProcess[str]] = run_command) -> list[dict[str, Any]]:
    active = drm_devices()
    active_addresses = {item.get("pciAddress") for item in active if item.get("pciAddress")}
    for device in boot_display_devices(runner):
        if device["pciAddress"] not in active_addresses:
            active.append(device)
    return active


def discrete_device_nodes(
    devices: list[dict[str, Any]],
    drm_root: Path = Path("/sys/class/drm"),
    dev_root: Path = Path("/dev"),
) -> set[Path]:
    """Return device nodes owned by the active discrete GPU without waking it."""
    addresses = {
        str(device.get("pciAddress", "")).removeprefix("0000:")
        for device in devices
        if device.get("kind") == "discrete" and device.get("present", True)
    }
    nodes: set[Path] = set()
    for entry in drm_root.glob("*"):
        if not re.fullmatch(r"(?:card\d+|renderD\d+)", entry.name):
            continue
        try:
            address = (entry / "device").resolve().name.removeprefix("0000:")
        except OSError:
            continue
        node = dev_root / "dri" / entry.name
        if address in addresses and node.exists():
            nodes.add(node)
    if any(device.get("vendor") == "nvidia" and device.get("present", True) for device in devices):
        nodes.update(path for path in dev_root.glob("nvidia*") if path.is_char_device())
    return nodes


def gpu_clients(
    devices: list[dict[str, Any]] | None = None,
    proc_root: Path = Path("/proc"),
    drm_root: Path = Path("/sys/class/drm"),
    dev_root: Path = Path("/dev"),
) -> dict[str, Any]:
    """Find current-user processes holding discrete GPU nodes."""
    devices = discover_gpu_devices() if devices is None else devices
    nodes = discrete_device_nodes(devices, drm_root, dev_root)
    device_ids = set()
    for node in nodes:
        try:
            device_ids.add(node.stat().st_rdev)
        except OSError:
            continue
    clients = []
    current_pid = os.getpid()
    current_uid = os.getuid()
    for process in proc_root.glob("[0-9]*"):
        try:
            pid = int(process.name)
            if pid == current_pid or process.stat().st_uid != current_uid:
                continue
            uses_gpu = any(fd.stat().st_rdev in device_ids for fd in (process / "fd").iterdir())
            if not uses_gpu:
                continue
            name = (process / "comm").read_text(encoding="utf-8").strip() or f"PID {pid}"
            clients.append({"pid": pid, "name": name[:80]})
        except (OSError, ValueError):
            continue
    clients.sort(key=lambda item: (item["name"].lower(), item["pid"]))
    return action(True, "ok", data={"count": len(clients), "clients": clients})


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def active_competitor(runner: Callable[..., subprocess.CompletedProcess[str]]) -> str | None:
    if not command_exists("systemctl"):
        return None
    for service in COMPETING_SERVICES:
        result = runner(["systemctl", "is-active", "--quiet", service])
        if result.returncode == 0:
            return service
    return None


def words(value: str) -> list[str]:
    return re.findall(r"[A-Za-z][A-Za-z0-9]+", value)


def map_supported(raw: str) -> tuple[list[str], dict[str, str]]:
    backend_words = set(words(raw))
    supported = []
    mapping = {}
    for standard in STANDARD_MODES:
        backend = next((item for item in SUPERGFX_MODES[standard] if item in backend_words), None)
        if backend:
            supported.append(standard)
            mapping[standard] = backend
    return supported, mapping


def map_current(raw: str, mapping: dict[str, str]) -> str:
    current_words = set(words(raw))
    return next((standard for standard, backend in mapping.items() if backend in current_words), "custom")


def map_pending_action(raw: str) -> str | None:
    normalised = raw.strip().lower().replace("_", "-")
    if "reboot" in normalised:
        return "reboot"
    if "logout" in normalised or "log-out" in normalised or "log out" in normalised:
        return "logout"
    return None


def classify_controller_error(completed: subprocess.CompletedProcess[str]) -> AdapterError:
    detail = f"{completed.stdout}\n{completed.stderr}".lower()
    if "denied" in detail or "permission" in detail or completed.returncode in (4, 126):
        return AdapterError("denied", "the graphics controller denied the request")
    if "busy" in detail or "in use" in detail or completed.returncode == 5:
        return AdapterError("busy", "the graphics controller is busy")
    return AdapterError("failed", "the graphics controller rejected the request")


def supergfx_session_api_available(
    runner: Callable[..., subprocess.CompletedProcess[str]],
    has_command: Callable[[str], bool],
) -> bool:
    """Check that logind exposes the session method used by supergfxd."""
    if not has_command("busctl"):
        return False
    completed = runner([
        "busctl", "introspect", "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "--no-pager",
    ])
    if completed.returncode != 0:
        return False
    return any(re.match(r"\s*\.ListSessions\s+method\s+", line) for line in completed.stdout.splitlines())


def gpu_snapshot(
    devices: list[dict[str, Any]] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    has_command: Callable[[str], bool] = command_exists,
) -> dict[str, Any]:
    devices = discover_gpu_devices(runner) if devices is None else devices
    integrated = sum(item.get("kind") == "integrated" for item in devices)
    discrete = sum(item.get("kind") == "discrete" for item in devices)
    discrete_on = any(item.get("kind") == "discrete" and item.get("present", True) for item in devices)
    reason = "no-gpu" if not devices else "no-switchable-gpu" if not (integrated and discrete) else "no-supported-controller"
    observed_mode = "unavailable" if not devices else "integrated" if integrated and not discrete_on else "custom"
    result = {
        "schemaVersion": 2,
        "devices": devices,
        "deviceCount": len(devices),
        "integratedCount": integrated,
        "discreteCount": discrete,
        "backend": "drm",
        "controller": "",
        "controllerMode": "",
        "mode": observed_mode,
        "label": MODE_LABELS.get(observed_mode, "GPU unavailable" if not devices else "Custom"),
        "tooltip": "No graphics device" if not devices else f"{len(devices)} graphics device{'s' if len(devices) != 1 else ''} detected",
        "supportedModes": [],
        "pendingMode": None,
        "pendingAction": None,
        "controlReason": reason,
        "gpuOn": discrete_on,
        "gpuUtil": "",
        "gpuTemp": "",
        "vramUsed": "",
        "vramTotal": "",
        "capability": capability(True, True, False, "not-required", reason),
    }
    if not (integrated and discrete) or not has_command("supergfxctl"):
        return result
    competitor = active_competitor(runner)
    if competitor:
        result["controlReason"] = "competing-controller-active"
        result["capability"] = capability(True, True, False, "denied", "competing-controller-active")
        return result
    result["controller"] = "supergfxctl"
    supported_result = runner(["supergfxctl", "--supported"])
    current_result = runner(["supergfxctl", "--get"])
    if supported_result.returncode != 0 or current_result.returncode != 0:
        failure = classify_controller_error(supported_result if supported_result.returncode else current_result)
        result["controlReason"] = failure.code
        permission = "denied" if failure.code == "denied" else "granted"
        result["capability"] = capability(True, True, False, permission, failure.code)
        return result
    supported, mapping = map_supported(supported_result.stdout)
    if not supported:
        return result
    mode = map_current(current_result.stdout, mapping)
    result.update({
        "controllerMode": current_result.stdout.strip(),
        "mode": mode,
        "label": MODE_LABELS.get(mode, "Custom"),
        "tooltip": f"{MODE_LABELS.get(mode, 'Custom')} via supergfxctl",
    })
    if not supergfx_session_api_available(runner, has_command):
        result["controlReason"] = "controller-incompatible"
        result["capability"] = capability(True, True, False, "not-required", "controller-incompatible")
        return result
    pending_mode_result = runner(["supergfxctl", "--pend-mode"])
    pending_action_result = runner(["supergfxctl", "--pend-action"])
    if pending_mode_result.returncode != 0 or pending_action_result.returncode != 0:
        failure = classify_controller_error(
            pending_mode_result if pending_mode_result.returncode else pending_action_result
        )
        result["controlReason"] = failure.code
        permission = "denied" if failure.code == "denied" else "granted"
        result["capability"] = capability(True, True, False, permission, failure.code)
        return result
    pending_mode = map_current(pending_mode_result.stdout, mapping)
    if pending_mode == "custom" or pending_mode == mode:
        pending_mode = None
    pending_action = map_pending_action(pending_action_result.stdout)
    result.update({
        "controller": "supergfxctl",
        "controllerMode": current_result.stdout.strip(),
        "mode": mode,
        "label": MODE_LABELS.get(mode, "Custom"),
        "tooltip": f"{MODE_LABELS.get(mode, 'Custom')} via supergfxctl",
        "supportedModes": supported,
        "pendingMode": pending_mode,
        "pendingAction": pending_action,
        "controlReason": "",
        "capability": capability(True, True, True, "granted", None),
    })
    return result


def set_gpu_mode(
    mode: str,
    expected_mode: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    mutation_started: Callable[[], None] | None = None,
    mode_runner: Callable[[list[str]], subprocess.CompletedProcess[str]] | None = None,
    verify_after: bool = True,
    pending_action_hint: str | None = None,
) -> dict[str, Any]:
    snapshot = gpu_snapshot(runner=runner)
    if snapshot["capability"]["canChange"] is not True:
        reason = snapshot["capability"]["reason"] or "unavailable"
        code = "denied" if snapshot["capability"]["permission"] == "denied" else "unavailable"
        raise AdapterError(code, f"GPU mode control is unavailable: {reason}")
    if snapshot["mode"] != expected_mode:
        raise AdapterError("stale", "the GPU mode changed before the request")
    if mode not in snapshot["supportedModes"]:
        raise AdapterError("invalid-data", "the requested GPU mode is unsupported")
    if mode == snapshot["mode"]:
        return action(True, "ok", data={"mode": mode, "changed": False, "pendingAction": snapshot["pendingAction"]})
    _, mapping = map_supported(" ".join(snapshot["supportedModes"] + list(sum(SUPERGFX_MODES.values(), ()))))
    backend_mode = mapping.get(mode)
    if not backend_mode:
        raise AdapterError("invalid-data", "the requested GPU mode has no controller mapping")
    if mutation_started is not None:
        mutation_started()
    completed = (mode_runner or runner)(["supergfxctl", "--mode", backend_mode])
    if completed.returncode != 0:
        raise classify_controller_error(completed)
    command_action = map_pending_action(f"{completed.stdout}\n{completed.stderr}")
    if not verify_after:
        return action(True, "ok", data={
            "mode": mode,
            "changed": True,
            "pendingAction": command_action or pending_action_hint,
        })
    after = gpu_snapshot(runner=runner)
    pending_action = after.get("pendingAction")
    if command_action is not None:
        pending_action = command_action
    if after["mode"] != mode and after.get("pendingMode") != mode:
        raise AdapterError("failed", "the GPU mode change could not be verified", {"failedStep": "verify", "observedMode": after["mode"]})
    return action(True, "ok", data={"mode": mode, "changed": True, "pendingAction": pending_action})


def parse_expected(value: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise AdapterError("invalid-data", "the expected monitor state is malformed") from error
    if not isinstance(parsed, dict):
        raise AdapterError("invalid-data", "the expected monitor state is invalid")
    return parsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="graphicsctl.py")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("monitors")
    refresh = commands.add_parser("set-refresh")
    refresh.add_argument("monitor")
    refresh.add_argument("rate")
    refresh.add_argument("expected")
    commands.add_parser("gpu")
    commands.add_parser("gpu-clients")
    gpu_mode = commands.add_parser("set-gpu-mode")
    gpu_mode.add_argument("mode", choices=STANDARD_MODES)
    gpu_mode.add_argument("expected_mode")
    gpu_mode.add_argument("--logout", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "monitors":
            output = query_monitors()
        elif args.command == "set-refresh":
            output = set_refresh(args.monitor, args.rate, parse_expected(args.expected))
        elif args.command == "gpu":
            output = gpu_snapshot()
        elif args.command == "gpu-clients":
            output = gpu_clients()
        else:
            output = set_gpu_mode(
                args.mode,
                args.expected_mode,
                mode_runner=(
                    lambda command: run_controller_then_logout(
                        command,
                        [str(Path(__file__).resolve().parent / "power/safe.sh"), "logout"],
                    )
                ) if args.logout else None,
                verify_after=not args.logout,
                pending_action_hint="logout" if args.logout else None,
            )
    except AdapterError as error:
        output = action(False, error.code, error.message, error.data)
        print(json.dumps(output, separators=(",", ":")))
        return {"invalid-data": 6, "denied": 4, "busy": 5, "stale": 5, "timeout": 5, "unavailable": 3}.get(error.code, 1)
    print(json.dumps(output, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
