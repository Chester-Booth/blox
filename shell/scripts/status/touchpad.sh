#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

state_file="${XDG_RUNTIME_DIR:-$HOME/.cache}/quickshell-touchpad-enabled"
enabled=true

device_output="$("$script_dir/touchpad-device.sh" 2>/dev/null)" || {
	emit_status '{"icon":"󰟸","class":"unavailable","device":"","devices":[],"touchpadCount":0,"enabled":false,"details":"Touchpad discovery unavailable","tooltip":"Touchpad discovery unavailable"}' false false false unknown command-unavailable
	exit 0
}
devices_json="$(printf '%s\n' "$device_output" | jq -Rsc 'split("\n") | map(select(length > 0))')"
device="$(jq -r '.[0] // ""' <<<"$devices_json")"

if [[ -r "$state_file" ]]; then
	read -r enabled <"$state_file"
fi

case "$enabled" in
true | false) ;;
*) enabled=true ;;
esac

if [[ "$enabled" == "true" ]]; then
	payload="$(jq -nc --arg device "$device" --argjson devices "$devices_json" --argjson enabled true '{icon:"󰟸",class:"enabled",device:$device,devices:$devices,touchpadCount:($devices | length),enabled:$enabled,details:"Touchpad enabled",tooltip:"Touchpad enabled"}')"
else
	payload="$(jq -nc --arg device "$device" --argjson devices "$devices_json" --argjson enabled false '{icon:"󰤳",class:"disabled",device:$device,devices:$devices,touchpadCount:($devices | length),enabled:$enabled,details:"Touchpad disabled",tooltip:"Touchpad disabled"}')"
fi
if [[ "$device" == "" ]]; then
	emit_status "$payload" true true false not-required device-unavailable
else
	emit_status "$payload" true true true not-required ""
fi
