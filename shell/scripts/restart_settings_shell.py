#!/usr/bin/env python3
"""Restart the user shell only when this Settings process owns its service."""
import subprocess
import sys


def restart(pid, runner=subprocess.run):
    result = runner(['systemctl', '--user', 'show', '--property=MainPID', '--value', 'quickshell.service'],
                    capture_output=True, text=True, check=True)
    if result.stdout.strip() != str(pid):
        raise RuntimeError('This Settings window is not running in quickshell.service. Restart its shell manually.')
    runner(['systemctl', '--user', 'restart', 'quickshell.service'], check=True)


if __name__ == '__main__':
    try:
        restart(int(sys.argv[1]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
