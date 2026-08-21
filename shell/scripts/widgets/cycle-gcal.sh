#!/usr/bin/env bash
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/widgets"
STATE_FILE="$STATE_DIR/gcal-current"
LOCK_FILE="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/quickshell/widget-gcal.lock"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TODO_DIR="$HOME/Documents/todo"

files=(
	"$TODO_DIR/2-gcal.md"
	"$TODO_DIR/80-today.md"
	"$TODO_DIR/81-week.md"
	"$TODO_DIR/99-gcal_week.md"
)

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -w 2 9 || exit 75

current="${files[0]}"
if [ -f "$STATE_FILE" ]; then
	current="$(cat "$STATE_FILE" 2>/dev/null || printf '%s\n' "${files[0]}")"
fi

current_index=-1
for i in "${!files[@]}"; do
	if [ "${files[$i]}" = "$current" ]; then
		current_index="$i"
		break
	fi
done

next_index=$(((current_index + 1) % ${#files[@]}))
state_tmp="${STATE_FILE}.$$"
printf '%s\n' "${files[$next_index]}" >"$state_tmp"
mv -f "$state_tmp" "$STATE_FILE"
flock -u 9

"$SCRIPT_DIR/../todo/generated-refresh.sh" >/dev/null 2>&1 || true
