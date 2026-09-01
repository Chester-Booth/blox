#!/usr/bin/env bash
set -euo pipefail

# Quickshell reads QS_ICON_THEME at process start. Read the active generated
# value here so Apply can change shell icons after the existing deferred
# Quickshell restart, while an explicit environment value still wins.
state_home="$(printenv XDG_STATE_HOME || true)"
if [[ -z "$state_home" ]]; then
	state_home="$HOME/.local/state"
fi
theme_file="$state_home/blox/theme/current/quickshell/theme.json"
configured_icon_theme="$(printenv QS_ICON_THEME || true)"
if [[ -z "$configured_icon_theme" && -r "$theme_file" ]]; then
	icon_theme="$(jq -r '.icons.theme // empty' "$theme_file" 2>/dev/null || true)"
	if [[ -n "$icon_theme" ]]; then
		export QS_ICON_THEME="$icon_theme"
	fi
fi

exec /usr/bin/quickshell "$@"
