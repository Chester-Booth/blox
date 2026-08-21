#!/usr/bin/env bash
set -u

title="${1:-Status}"
message="${2:-}"
icon="${3:-󰋼}"
level="${4:-normal}"
duration="${5:-1200}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"$script_dir/ipc.sh" osd notice "$title" "$message" "$icon" "$level" "$duration" >/dev/null 2>&1 || true
