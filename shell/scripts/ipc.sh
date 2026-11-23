#!/usr/bin/env bash
set -euo pipefail

if (($# < 2)); then
	echo "Usage: ipc.sh <target> <function> [argument ...]" >&2
	exit 2
fi

service_quickshell_pid() {
	local process_id process_name
	process_id="$(systemctl --user show --property MainPID --value quickshell.service 2>/dev/null || true)"
	[[ "$process_id" =~ ^[0-9]+$ ]] && ((process_id > 1)) || return 1
	IFS= read -r process_name <"/proc/$process_id/comm" 2>/dev/null || return 1
	[[ "$process_name" == "quickshell" ]] || return 1
	printf '%s\n' "$process_id"
}

if [[ -n "${QUICKSHELL_IPC_PID:-}" ]]; then
	if [[ ! "$QUICKSHELL_IPC_PID" =~ ^[0-9]+$ ]] || ((QUICKSHELL_IPC_PID <= 1)); then
		echo "Invalid Quickshell PID" >&2
		exit 3
	fi
	main_pid="$QUICKSHELL_IPC_PID"
else
	if ! main_pid="$(service_quickshell_pid)"; then
		echo "Blox IPC unavailable for the current shell generation." >&2
		exit 3
	fi
fi

# Quickshell 0.3.0 requires IPC options after the `ipc` subcommand. Putting
# global options before it can launch a shell instead of an IPC client.
exec quickshell ipc --pid "$main_pid" call "$@"
