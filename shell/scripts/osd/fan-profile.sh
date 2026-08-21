#!/usr/bin/env bash
set -u

profile="${1:-balanced}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"$script_dir/ipc.sh" osd fan "$profile" >/dev/null 2>&1 || true
