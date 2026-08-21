#!/usr/bin/env bash
set -u

# shellcheck source=../status/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../status" && pwd)/common.sh"

TODO_DIR="$HOME/Documents/todo"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/todo"
STATE_FILE="$STATE_DIR/current-index"
CURRENT_FILE="$STATE_DIR/current-file"

mkdir -p "$TODO_DIR" "$STATE_DIR"
mapfile -t files < <(find "$TODO_DIR" -maxdepth 1 -type f -name "*.md" | sort)

if [ "${#files[@]}" -eq 0 ]; then
	touch "$TODO_DIR/todo.md"
	files=("$TODO_DIR/todo.md")
fi

current_index=0
if [ -f "$STATE_FILE" ]; then
	current_index="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
fi

if ! [[ "$current_index" =~ ^[0-9]+$ ]] || [ "$current_index" -ge "${#files[@]}" ]; then
	current_index=0
fi

current_file="${files[$current_index]}"
content="$(cat "$current_file" 2>/dev/null || true)"
filename="$(basename "$current_file")"

current_tmp="${CURRENT_FILE}.$$"
printf '%s\n' "$current_file" >"$current_tmp"
mv -f "$current_tmp" "$CURRENT_FILE"

payload="$(jq -nc \
	--arg file "$current_file" \
	--arg name "$filename" \
	--arg raw "$content" \
	--argjson index "$current_index" \
	--argjson count "${#files[@]}" \
	'{"text":"󰺦","file":$file,"name":$name,"raw":$raw,"index":$index,"count":$count,"tooltip":("# " + $name + " " + (($index + 1)|tostring) + "/" + ($count|tostring) + "\n\n" + $raw)}')"
emit_status "$payload" true true true granted ""
