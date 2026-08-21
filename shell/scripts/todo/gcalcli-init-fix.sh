#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/gcalcli-init-fix.py"

if [ "${GCALCLI_INIT_FIX_IN_TERMINAL:-0}" = "1" ] || [ -n "${INSIDE_KITTY:-}" ]; then
	"$HELPER"
	exit $?
fi

if command -v kitty >/dev/null 2>&1; then
	exec kitty --title "Google Calendar Auth" bash -lc \
		"GCALCLI_INIT_FIX_IN_TERMINAL=1 '$HELPER'; status=\$?; echo; read -r -p 'Press Enter to close...'; exit \$status"
fi

exec "$HELPER"
