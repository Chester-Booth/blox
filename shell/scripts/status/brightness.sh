#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

requested_device="${1:-}"
state_file="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/blue-light-mode"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

mapfile -t backlights < <("$script_dir/status/brightness-device.sh" --list 2>/dev/null || true)
device="$requested_device"
if [[ -z "$device" && "${#backlights[@]}" -gt 0 ]]; then
	device="${backlights[0]}"
fi

backlights_json="$(printf '%s\n' "${backlights[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

ddc_available=false
ddc_display_count=0
ddc_reason="command-unavailable"
if command -v ddcutil >/dev/null 2>&1; then
	ddc_reason="no-ddc-display"
	ddc_output=""
	ddc_exit=0
	ddc_output="$(timeout 3s ddcutil detect --brief 2>/dev/null)" || ddc_exit=$?
	if [[ "$ddc_exit" -eq 124 ]]; then
		ddc_reason="timeout"
	else
		ddc_display_count="$(printf '%s\n' "$ddc_output" | awk '/^Display [0-9]+/ {count++} END {print count + 0}')"
		if [[ "$ddc_display_count" -gt 0 ]]; then
			ddc_available=true
			ddc_reason=""
		fi
	fi
fi

if ! command -v brightnessctl >/dev/null 2>&1; then
	emit_status "$(jq -nc --argjson backlights "$backlights_json" --argjson ddcDisplays "$ddc_display_count" --arg ddcReason "$ddc_reason" \
		'{icon:"󰃠",percent:0,blueLightMode:"auto",blueLightActive:false,device:"",backlightCount:($backlights|length),backlights:$backlights,ddcAvailable:false,ddcDisplayCount:$ddcDisplays,ddcReason:$ddcReason,details:"Brightness status unavailable",tooltip:"Brightness status unavailable"}')" false false false unknown "command-unavailable"
	exit 0
fi

if [[ -z "$device" ]]; then
	emit_status "$(jq -nc --argjson backlights "$backlights_json" --argjson ddcDisplays "$ddc_display_count" --arg ddcReason "$ddc_reason" \
		'{icon:"󰃠",percent:0,blueLightMode:"auto",blueLightActive:false,device:"",backlightCount:($backlights|length),backlights:$backlights,ddcAvailable:false,ddcDisplayCount:$ddcDisplays,ddcReason:$ddcReason,details:"No backlight device",tooltip:"Brightness status unavailable"}')" true true false not-required "device-unavailable"
	exit 0
fi

percent="$(brightnessctl -d "$device" -m 2>/dev/null | awk -F, '{gsub(/%/, "", $4); print $4}')"
if [[ ! "$percent" =~ ^[0-9]+$ ]]; then
	emit_status "$(jq -nc --arg device "$device" --argjson backlights "$backlights_json" --argjson ddcDisplays "$ddc_display_count" --arg ddcReason "$ddc_reason" \
		'{icon:"󰃠",percent:0,blueLightMode:"auto",blueLightActive:false,device:$device,backlightCount:($backlights|length),backlights:$backlights,ddcAvailable:false,ddcDisplayCount:$ddcDisplays,ddcReason:$ddcReason,details:"No brightness device",tooltip:"Brightness status unavailable"}')" true true false not-required "device-unavailable"
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
	--arg device "$device" \
	--argjson backlights "$backlights_json" \
	--argjson ddcAvailable "$ddc_available" \
	--argjson ddcDisplays "$ddc_display_count" \
	--arg ddcReason "$ddc_reason" \
	--arg blueMode "$blue_mode" \
	--argjson percent "$percent" \
	--argjson blueActive "$blue_active" \
	'{icon:$icon,percent:$percent,blueLightMode:$blueMode,blueLightActive:$blueActive,device:$device,backlightCount:($backlights|length),backlights:$backlights,ddcAvailable:$ddcAvailable,ddcDisplayCount:$ddcDisplays,ddcReason:$ddcReason,details:("Brightness: \($percent)%\nBlue light: \($blueMode)" + (if $blueActive then " active" else " inactive" end)),tooltip:("Brightness: \($percent)%\nBlue light: \($blueMode)" + (if $blueActive then " active" else " inactive" end))}')"
emit_status "$payload" true true true granted ""
