#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if ! command -v pactl >/dev/null 2>&1; then
	emit_status '{"icon":"󰝟","micIcon":"󰍭","volume":0,"muted":true,"micMuted":true,"tooltip":"Audio status unavailable"}' false false false unknown "command-unavailable"
	exit 0
fi

sink_volume="$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk -F'/' 'NR==1 { gsub(/[ %]/, "", $2); print $2 }')"
sink_mute="$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')"
source_mute="$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null | awk '{print $2}')"
sink_desc="$(pactl get-default-sink 2>/dev/null)"

if [[ ! "$sink_volume" =~ ^[0-9]+$ || -z "$sink_desc" ]]; then
	emit_status '{"icon":"󰝟","micIcon":"󰍭","volume":0,"muted":true,"micMuted":true,"tooltip":"Audio status unavailable"}' true false false unknown "query-failed"
	exit 0
fi

[[ -n "$sink_mute" ]] || sink_mute=yes
[[ -n "$source_mute" ]] || source_mute=yes

if [[ "$sink_mute" == "yes" ]]; then
	icon="󰝟"
elif ((sink_volume > 100)); then
	icon="󰝝"
elif ((sink_volume < 35)); then
	icon="󰕿"
elif ((sink_volume < 70)); then
	icon="󰖀"
else
	icon="󰕾"
fi

mic_icon="󰍬"
[[ "$source_mute" == "yes" ]] && mic_icon="󰍭"

payload="$(jq -nc \
	--arg icon "$icon" \
	--arg micIcon "$mic_icon" \
	--arg sinkMute "$sink_mute" \
	--arg sourceMute "$source_mute" \
	--arg desc "$sink_desc" \
	--argjson volume "$sink_volume" \
	'{icon:$icon,micIcon:$micIcon,volume:$volume,muted:($sinkMute=="yes"),micMuted:($sourceMute=="yes"),tooltip:("Volume: \($volume)%\n\($desc)\nMic muted: \($sourceMute)")}')"
emit_status "$payload" true true true granted ""
