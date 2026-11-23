#!/usr/bin/env python3
"""Float this shell's transient Settings window at its requested size on Hyprland."""
import json
import subprocess
import sys
import time


def place(title, pid, width, height, parent_title=""):
    for _ in range(10):
        result = subprocess.run(['hyprctl', 'clients', '-j'], capture_output=True, text=True, check=True)
        matches = [window for window in json.loads(result.stdout)
                   if window.get('title') == title and window.get('pid') == pid]
        if matches:
            window = matches[-1]
            address = json.dumps('address:' + window['address'])
            for operation in [f'float({{ action = "on", window = {address} }})',
                              f'resize({{ x = {width}, y = {height}, relative = false, window = {address} }})']:
                subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.window.' + operation], check=True, capture_output=True)
            parents = [entry for entry in json.loads(result.stdout)
                       if parent_title and entry.get('title') == parent_title and entry.get('pid') == pid]
            if parents:
                parent = parents[-1]
                x = parent['at'][0] + (parent['size'][0] - width) // 2
                y = parent['at'][1] + (parent['size'][1] - height) // 2
                operation = f'move({{ x = {x}, y = {y}, relative = false, window = {address} }})'
                subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.window.' + operation], check=True, capture_output=True)
            return
        time.sleep(0.04)
    raise RuntimeError('Settings window did not map')


if __name__ == '__main__':
    place(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] if len(sys.argv) > 5 else "")
