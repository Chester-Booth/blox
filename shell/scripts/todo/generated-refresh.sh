#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TODO_DIR="$HOME/Documents/todo"
EXPENSES_API_BASE_URL="${EXPENSES_API_BASE_URL:-}"
runtime_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/quickshell"

mkdir -p "$TODO_DIR" "$runtime_dir"
exec 9>"$runtime_dir/generated-refresh.lock"
flock -n 9 || exit 75

"$SCRIPT_DIR/update-gcal-md.sh" || true

if [ -n "$EXPENSES_API_BASE_URL" ]; then
	today_tmp="$(mktemp)"
	week_tmp="$(mktemp)"

	curl -fsS --connect-timeout 2 --max-time 8 \
		-X POST "$EXPENSES_API_BASE_URL/api/exports/regenerate" >/dev/null || true

	if curl -fsS --connect-timeout 2 --max-time 6 \
		"$EXPENSES_API_BASE_URL/api/chart/today-text" >"$today_tmp"; then
		mv "$today_tmp" "$TODO_DIR/80-today.md"
	else
		rm -f "$today_tmp"
	fi

	if curl -fsS --connect-timeout 2 --max-time 6 \
		"$EXPENSES_API_BASE_URL/api/chart/week-text" >"$week_tmp"; then
		mv "$week_tmp" "$TODO_DIR/81-week.md"
	else
		rm -f "$week_tmp"
	fi
fi
