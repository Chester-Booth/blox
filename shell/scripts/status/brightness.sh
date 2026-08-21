#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

device="${1:-amdgpu_bl1}"
state_file="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/blue-light-mode"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v brightnessctl >/dev/null 2>&1; then
	emit_status '{"icon":"󰃠","percent":0,"blueLightMode":"auto","blueLightActive":false,"details":"Brightness status unavailable","tooltip":"Brightness status unavailable"}' false false false unknown "command-unavailable"
	exit 0
fi

percent="$(brightnessctl -d "$device" -m 2>/dev/null | awk -F, '{gsub(/%/, "", $4); print $4}')"
if [[ ! "$percent" =~ ^[0-9]+$ ]]; then
	emit_status '{"icon":"󰃠","percent":0,"blueLightMode":"auto","blueLightActive":false,"details":"No brightness device","tooltip":"Brightness status unavailable"}' false false false unknown "device-unavailable"
	exit 0
fi
((percent > 100)) && percent=100

icons=(󰃚 󰃛 󰃜 󰃝 󰃞 󰃟 󰃠)
index=$((percent / 17))
((index > 6)) && index=6

blue_mode="auto"
[[ -r "$state_file" ]] && read -r blue_mode <"$state_file"
case "$blue_mode" in
on | auto | off) ;;
*) blue_mode="auto" ;;
esac

blue_active="$("$script_dir/display/blue-light-active.sh" 2>/dev/null || printf 'false')"
[[ "$blue_active" == "true" || "$blue_active" == "false" ]] || blue_active=false

payload="$(jq -nc \
	--arg icon "${icons[$index]}" \
	--arg blueMode "$blue_mode" \
	--argjson percent "$percent" \
	--argjson blueActive "$blue_active" \
	'{icon:$icon,percent:$percent,blueLightMode:$blueMode,blueLightActive:$blueActive,details:("Brightness: \($percent)%\nBlue light: \($blueMode)" + (if $blueActive then " active" else " inactive" end)),tooltip:("Brightness: \($percent)%\nBlue light: \($blueMode)" + (if $blueActive then " active" else " inactive" end))}')"
emit_status "$payload" true true true granted ""
