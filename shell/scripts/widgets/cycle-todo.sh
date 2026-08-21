#!/usr/bin/env bash
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/widgets"
STATE_FILE="$STATE_DIR/todo-current"
LOCK_FILE="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/quickshell/widget-todo.lock"
TODO_DIR="$HOME/Documents/todo"

mkdir -p "$TODO_DIR" "$STATE_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -w 2 9 || exit 75
mapfile -t files < <(find "$TODO_DIR" -maxdepth 1 -type f -name "*.md" | grep -Ev '/(2-gcal|80-today|81-week|99-gcal_week)\.md$' | sort)

if [ "${#files[@]}" -eq 0 ]; then
	printf '%s\n' "$TODO_DIR/1-todo.md"
	exit 0
fi

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
