#!/usr/bin/env bash
set -u

STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/widgets/gcal-current"
TODO_DIR="$HOME/Documents/todo"

current="$TODO_DIR/2-gcal.md"
if [ -f "$STATE_FILE" ]; then
	current="$(cat "$STATE_FILE" 2>/dev/null || printf '%s\n' "$current")"
fi

if [ -f "$current" ]; then
	cat "$current"
else
	printf 'File not found\n'
fi
