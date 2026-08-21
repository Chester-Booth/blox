#!/usr/bin/env bash
set -u

mode="${1:-auto}"
active="${2:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$active" ]]; then
	active="$("$script_dir/display/blue-light-active.sh" 2>/dev/null || printf 'false')"
fi

"$script_dir/ipc.sh" osd blueLight "$mode" "$active" >/dev/null 2>&1 || true
