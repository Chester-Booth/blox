#!/usr/bin/env python3
"""Float this shell's transient Settings window at its requested size on Hyprland."""
import json
import subprocess
import sys
import time


def _monitor_work_area(clients_result, target_window):
    """Return (x, y, w, h) usable area for target_window's monitor, or None."""
    try:
        monitors = json.loads(subprocess.run(['hyprctl', 'monitors', '-j'], capture_output=True, text=True, check=True).stdout)
    except Exception:
        return None
    if not isinstance(monitors, list) or not monitors:
        return None
    monitor_id = target_window.get('monitor')
    monitor = next((m for m in monitors if isinstance(m, dict) and m.get('id') == monitor_id), None)
    if monitor is None:
        monitor = next((m for m in monitors if isinstance(m, dict) and m.get('focused')), monitors[0])
    if not isinstance(monitor, dict) or 'width' not in monitor or 'height' not in monitor:
        return None
    scale = float(monitor.get('scale') or 1.0) or 1.0
    reserved = monitor.get('reserved') or [0, 0, 0, 0]
    left, top, right, bottom = [int(v) for v in (list(reserved) + [0, 0, 0, 0])[:4]]
    mx = int(monitor.get('x', 0)) + left
    my = int(monitor.get('y', 0)) + top
    mw = max(1, int(round(monitor['width'] / scale)) - left - right)
    mh = max(1, int(round(monitor['height'] / scale)) - top - bottom)
    return mx, my, mw, mh


def _clamp_position(x, y, width, height, work_area):
    if not work_area:
        return x, y
    mx, my, mw, mh = work_area
    pad = 8
    max_x = max(mx + pad, mx + mw - width - pad)
    max_y = max(my + pad, my + mh - height - pad)
    return max(mx + pad, min(max_x, x)), max(my + pad, min(max_y, y))


def place(title, pid, width, height, parent_title=""):
    for _ in range(10):
        result = subprocess.run(['hyprctl', 'clients', '-j'], capture_output=True, text=True, check=True)
        clients = json.loads(result.stdout)
        matches = [window for window in clients
                   if window.get('title') == title and window.get('pid') == pid]
        if matches:
            window = matches[-1]
            address = json.dumps('address:' + window['address'])
            for operation in [f'float({{ action = "on", window = {address} }})',
                              f'resize({{ x = {width}, y = {height}, relative = false, window = {address} }})']:
                subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.window.' + operation], check=True, capture_output=True)
            work_area = _monitor_work_area(result, window)
            parents = [entry for entry in clients
                       if parent_title and entry.get('title') == parent_title and entry.get('pid') == pid]
            if parents:
                parent = parents[-1]
                x = parent['at'][0] + (parent['size'][0] - width) // 2
                y = parent['at'][1] + (parent['size'][1] - height) // 2
                x, y = _clamp_position(x, y, width, height, work_area)
            elif work_area:
                mx, my, mw, mh = work_area
                x = mx + (mw - width) // 2
                y = my + (mh - height) // 2
                x, y = _clamp_position(x, y, width, height, work_area)
            else:
                x, y = None, None
            # Focus and raise the transient dialog so it stays above tiled Settings.
            subprocess.run(['hyprctl', 'dispatch', f'hl.dsp.focus({{ window = {address} }})'], check=False, capture_output=True)
            subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.window.bring_to_top()'], check=False, capture_output=True)
            if x is not None and y is not None:
                operation = f'move({{ x = {x}, y = {y}, relative = false, window = {address} }})'
                subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.window.' + operation], check=True, capture_output=True)
            return
        time.sleep(0.04)
    raise RuntimeError('Settings window did not map')


if __name__ == '__main__':
    place(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] if len(sys.argv) > 5 else "")
