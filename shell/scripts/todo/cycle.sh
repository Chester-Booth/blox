#!/usr/bin/env bash
set -u

delta="${1:-1}"
TODO_DIR="$HOME/Documents/todo"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/todo"
STATE_FILE="$STATE_DIR/current-index"
LOCK_FILE="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/quickshell/todo-cycle.lock"

mkdir -p "$TODO_DIR" "$STATE_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -w 2 9 || exit 75
mapfile -t files < <(find "$TODO_DIR" -maxdepth 1 -type f -name "*.md" | sort)
count="${#files[@]}"

if [ "$count" -eq 0 ]; then
	touch "$TODO_DIR/todo.md"
	count=1
fi

current=0
if [ -f "$STATE_FILE" ]; then
	current="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
fi

[[ "$current" =~ ^-?[0-9]+$ ]] || current=0
[[ "$delta" =~ ^-?[0-9]+$ ]] || delta=1

next=$(((current + delta) % count))
if [ "$next" -lt 0 ]; then
	next=$((next + count))
fi

state_tmp="${STATE_FILE}.$$"
printf '%s\n' "$next" >"$state_tmp"
mv -f "$state_tmp" "$STATE_FILE"
