#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if ! command -v nmcli >/dev/null 2>&1; then
	emit_status '{"icon":"󰤩","class":"error","summary":"Network status unavailable","details":"NetworkManager is not installed","tooltip":"Network status unavailable"}' false false false unknown "command-unavailable"
	exit 0
fi

wifi="$(nmcli -t -f WIFI general 2>/dev/null || true)"
if [[ -z "$wifi" ]]; then
	emit_status '{"icon":"󰤩","class":"error","summary":"Network status unavailable","details":"NetworkManager did not return a state","tooltip":"Network status unavailable"}' true false false unknown "query-failed"
	exit 0
fi

active="$(nmcli -t -f ACTIVE,SSID,SIGNAL,FREQ,DEVICE dev wifi 2>/dev/null | awk -F: '$1=="yes"{print; exit}')"

if [[ "$wifi" != "enabled" ]]; then
	emit_status '{"icon":"󰤭","class":"disabled","summary":"Wi-Fi disabled","details":"Wi-Fi is disabled","tooltip":"Wi-Fi disabled"}' true true true granted ""
	exit 0
fi

if [[ -z "$active" ]]; then
	emit_status '{"icon":"󰤩","class":"disconnected","summary":"Wi-Fi disconnected","details":"No active Wi-Fi connection","tooltip":"Wi-Fi disconnected"}' true true true granted ""
	exit 0
fi

IFS=: read -r _ ssid signal freq device <<<"$active"
signal="${signal:-0}"
freq="${freq% MHz}"
if [[ ! "$signal" =~ ^[0-9]+$ ]]; then
	signal=0
fi
icons=(󰤯 󰤟 󰤢 󰤥 󰤨)
index=$((signal / 25))
((index > 4)) && index=4

payload="$(jq -nc \
	--arg icon "${icons[$index]}" \
	--arg ssid "$ssid" \
	--arg freq "$freq" \
	--arg device "$device" \
	--argjson signal "$signal" \
	'{icon:$icon,class:"wifi",summary:$ssid,ssid:$ssid,signal:$signal,freq:$freq,device:$device,details:("Signal: \($signal)%\n\($freq) MHz\n\($device)"),tooltip:("\($ssid)\nSignal: \($signal)%\n\($freq) MHz\n\($device)")}' )"
emit_status "$payload" true true true granted ""
