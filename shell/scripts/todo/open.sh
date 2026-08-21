#!/bin/bash

state_file="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/todo/current-file"

# Get the current file from the state file
if [ -f "$state_file" ]; then
	current_file=$(cat "$state_file")
else
	current_file="$HOME/Documents/todo/1-todo.md"
fi

## if current file is 2-gcal.md or 99-gcal_week.md set to todo
if [[ "$current_file" == *"2-gcal.md"* || "$current_file" == *"99-gcal_week.md"* ]]; then
	current_file="$HOME/Documents/todo/1-todo.md"
fi

micro_bin="${MICRO_BIN:-$HOME/.local/bin/micro}"
if [ ! -x "$micro_bin" ]; then
	micro_bin="$(command -v micro 2>/dev/null || true)"
fi

if [ -z "$micro_bin" ]; then
	exit 1
fi

# Open the current file in kitty with micro editor and glow preview
# shellcheck disable=SC2016 # Positional parameters are expanded by the nested shell.
kitty --class todo --title todo sh -c '"$1" "$2" && glow "$2" && echo "Done - press enter"; read' sh "$micro_bin" "$current_file"
