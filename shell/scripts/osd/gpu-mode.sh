#!/usr/bin/env bash
set -u

mode="${1:-eco}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"$script_dir/ipc.sh" osd gpu "$mode" >/dev/null 2>&1 || true
