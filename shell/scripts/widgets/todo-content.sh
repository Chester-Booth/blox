#!/usr/bin/env bash
set -u

STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/widgets/todo-current"
TODO_DIR="$HOME/Documents/todo"

current="$TODO_DIR/1-todo.md"
if [ -f "$STATE_FILE" ]; then
	current="$(cat "$STATE_FILE" 2>/dev/null || printf '%s\n' "$current")"
fi

mapfile -t files < <(find "$TODO_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null | grep -Ev '/(2-gcal|80-today|81-week|99-gcal_week)\.md$' | sort)
count="${#files[@]}"

pos=1
for i in "${!files[@]}"; do
	if [ "${files[$i]}" = "$current" ]; then
		pos=$((i + 1))
		break
	fi
done

filename="$(basename "$current")"

if [ -f "$current" ]; then
	content="$(cat "$current")"
else
	content="File not found"
fi

printf '# %s %s/%s\n%s\n' "$filename" "$pos" "$count" "$content"
