#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if ! command -v bluetoothctl >/dev/null 2>&1; then
	emit_status '{"icon":"󰂯","class":"none","details":"Bluetooth status unavailable","tooltip":"Bluetooth status unavailable"}' false false false unknown "command-unavailable"
	exit 0
fi

show="$(bluetoothctl show 2>/dev/null || true)"
powered="$(awk -F': ' '/Powered:/ {print $2; exit}' <<<"$show")"
connected="$(bluetoothctl devices Connected 2>/dev/null | sed 's/^Device [^ ]* //' | paste -sd ', ' -)"

if [[ -z "$show" ]]; then
	emit_status '{"icon":"󰂯","class":"none","details":"No Bluetooth controller","tooltip":"No Bluetooth controller"}' false false false unknown "device-unavailable"
elif [[ "$powered" != "yes" ]]; then
	payload="$(jq -nc '{"icon":"󰂲","class":"disabled","details":"Bluetooth is off","tooltip":"Bluetooth off"}')"
	emit_status "$payload" true true true granted ""
elif [[ -n "$connected" ]]; then
	payload="$(jq -nc --arg connected "$connected" '{"icon":"󰂱","class":"connected","details":("Connected: " + $connected),"tooltip":("Connected: " + $connected)}')"
	emit_status "$payload" true true true granted ""
else
	emit_status '{"icon":"󰂯","class":"on","details":"No connected devices","tooltip":"Bluetooth on"}' true true true granted ""
fi
