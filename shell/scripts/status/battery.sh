#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/battery-status.json"

battery_dir=""
for candidate in /sys/class/power_supply/BAT*; do
	[[ -r "$candidate/capacity" ]] || continue
	battery_dir="$candidate"
	break
done

capacity=""
status=""
time_label="N/A"
if [[ -n "$battery_dir" ]]; then
	read -r capacity <"$battery_dir/capacity" || capacity=""
	read -r status <"$battery_dir/status" || status="Unknown"
fi

if [[ ! "$capacity" =~ ^[0-9]+$ ]]; then
	if [[ -s "$CACHE_FILE" ]] && jq -e '.icon | type == "string"' "$CACHE_FILE" >/dev/null 2>&1 &&
		jq -e '.class | type == "string"' "$CACHE_FILE" >/dev/null 2>&1 &&
		jq -e '.status | type == "string"' "$CACHE_FILE" >/dev/null 2>&1 &&
		jq -e '.timeLabel | type == "string"' "$CACHE_FILE" >/dev/null 2>&1; then
		emit_status "$(cat "$CACHE_FILE")" true false false not-required "stale"
		exit 0
	fi

	emit_status '{"icon":"󰚥","class":"plugged","capacity":"","status":"Unknown","timeLabel":"N/A","tooltip":"No battery detected"}' false false false not-required "device-unavailable"
	exit 0
fi

((capacity > 100)) && capacity=100

energy_now="$(cat "$battery_dir/energy_now" 2>/dev/null || true)"
energy_full="$(cat "$battery_dir/energy_full" 2>/dev/null || true)"
power_now="$(cat "$battery_dir/power_now" 2>/dev/null || true)"
if [[ "$energy_now" =~ ^[0-9]+$ && "$energy_full" =~ ^[0-9]+$ && "$power_now" =~ ^[0-9]+$ ]] &&
	((power_now > 0)); then
	if [[ "$status" == "Charging" ]]; then
		remaining_energy=$((energy_full - energy_now))
		((remaining_energy < 0)) && remaining_energy=0
		suffix=" to full"
	else
		remaining_energy=$energy_now
		suffix=" left"
	fi
	remaining_minutes=$((remaining_energy * 60 / power_now))
	time_label="$((remaining_minutes / 60))h $((remaining_minutes % 60))m$suffix"
elif [[ "$status" == "Full" ]]; then
	time_label="Full"
elif [[ "$status" == "Not charging" ]]; then
	time_label="Plugged in"
fi

icon="󰁹"
class="normal"

if [[ "$status" == "Charging" ]]; then
	icons=(󰢟 󰢜 󰂆 󰂇 󰂈 󰢝 󰂉 󰢞 󰂊 󰂋 󰂅)
	index=$((capacity / 10))
	((index > 10)) && index=10
	icon="${icons[$index]}"
	class="charging"
elif [[ "$status" == "Full" || "$status" == "Not charging" ]]; then
	icon="󰂅"
	class="plugged"
elif ((capacity <= 10)); then
	icon="󰂃"
	class="critical"
else
	icons=(󰁺 󰁻 󰁼 󰁽 󰁾 󰁿 󰂀 󰂁 󰂂 󰁹)
	index=$((capacity / 10))
	((index > 9)) && index=9
	icon="${icons[$index]}"
fi

mkdir -p "$(dirname "$CACHE_FILE")"
json="$(jq -nc --arg icon "$icon" --arg class "$class" --arg status "$status" --arg timeLabel "$time_label" --argjson capacity "$capacity" \
	'{icon:$icon,class:$class,capacity:$capacity,status:$status,timeLabel:$timeLabel,tooltip:("Charge: \($capacity)%\n\($status)\n\($timeLabel)")}')"
cache_tmp="${CACHE_FILE}.$$"
printf '%s\n' "$json" >"$cache_tmp"
mv -f "$cache_tmp" "$CACHE_FILE"
	emit_status "$json" true true false not-required ""
