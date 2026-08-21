#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

state_file="${XDG_RUNTIME_DIR:-$HOME/.cache}/quickshell-touchpad-enabled"
enabled=true

if [[ -r "$state_file" ]]; then
	read -r enabled <"$state_file"
fi

case "$enabled" in
true | false) ;;
*) enabled=true ;;
esac

if [[ "$enabled" == "true" ]]; then
	payload='{"icon":"󰟸","class":"enabled","enabled":true,"tooltip":"Touchpad enabled"}'
else
	payload='{"icon":"󰤳","class":"disabled","enabled":false,"tooltip":"Touchpad disabled"}'
fi
emit_status "$payload" true true true granted ""
