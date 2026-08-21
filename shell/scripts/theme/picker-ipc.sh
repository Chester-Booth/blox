#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
open | generateCurrent | status | cancel)
	action=$1
	;;
*)
	echo "Usage: picker-ipc.sh {open|generateCurrent|status|cancel}" >&2
	exit 2
	;;
esac

script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$script_root/ipc.sh" themePicker "$action"
