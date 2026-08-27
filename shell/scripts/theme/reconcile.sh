#!/usr/bin/env bash

set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
install_root=${BLOX_INSTALL_ROOT:-${HOME}/.local/share/blox}

# Startup must use the installed product CLI. The live dotfiles checkout can
# contain an older theme runtime than the product currently running the shell.
if [ -n "${BLOX_THEMECTL:-}" ]; then
	theme_cli=${BLOX_THEMECTL}
elif [ -x "${HOME}/.local/bin/themectl" ]; then
	theme_cli=${HOME}/.local/bin/themectl
elif [ -x "${install_root}/bin/themectl" ]; then
	theme_cli=${install_root}/bin/themectl
else
	repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || repo_root=""
	theme_cli=${repo_root:+${repo_root}/themes/bin/themectl}
fi

log_output() {
	if command -v systemd-cat >/dev/null 2>&1; then
		systemd-cat -t blox-theme-reconcile -p info
	else
		cat
	fi
}

run_logged() {
	local output status
	output=$("$theme_cli" "$@" --json 2>&1)
	status=$?
	printf '%s\n' "$output" | log_output
	printf 'command=%q status=%s\n' "$theme_cli $*" "$status" | log_output
	return "$status"
}

if [ -z "$theme_cli" ] || [ ! -x "$theme_cli" ]; then
	printf 'theme CLI is unavailable: %s\n' "${theme_cli:-<none>}" | log_output
	exit 127
fi

# Reconcile every active target once, as before. Exit 7 means the command
# completed with reload warnings, so it is not a hard failure here.
run_logged reconcile
full_status=$?
full_failed=0
if [ "$full_status" -ne 0 ] && [ "$full_status" -ne 7 ]; then
	full_failed=1
fi

# Cursor application talks to Hyprland and the running shell over separate
# IPC paths. Retry only this target after the full reconcile so a startup race
# cannot leave the compositor with its static fallback cursor.
cursor_enabled=1
active_manifest=${XDG_STATE_HOME:-${HOME}/.local/state}/blox-theme/active.json
if command -v jq >/dev/null 2>&1 && [ -f "$active_manifest" ]; then
	if ! jq -e '.enabled_targets | index("cursor") != null' "$active_manifest" >/dev/null 2>&1; then
		cursor_enabled=0
	fi
fi

cursor_failed=0
if [ "$cursor_enabled" -eq 1 ]; then
	for delay in 0 1 2 4 8; do
		if [ "$delay" -gt 0 ]; then
			sleep "$delay"
		fi
		run_logged reconcile --targets cursor
		cursor_status=$?
		if [ "$cursor_status" -eq 0 ]; then
			cursor_failed=0
			break
		fi
		cursor_failed=1
	done
else
	printf 'cursor target is disabled in the active theme\n' | log_output
fi

if [ "$full_failed" -ne 0 ] || [ "$cursor_failed" -ne 0 ]; then
	exit 1
fi
