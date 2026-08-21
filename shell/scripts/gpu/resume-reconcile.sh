#!/bin/bash

set -u

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
notice="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/blox/scripts/osd/notice.sh"
log_tag="gpu-resume-reconcile"
max_attempts=6
sleep_between=4

battery_is_discharging() {
	local battery_dir status

	for battery_dir in /sys/class/power_supply/BAT*; do
		if [[ -r "$battery_dir/status" ]]; then
			read -r status <"$battery_dir/status"
			status="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"
			[[ "$status" == "discharging" || "$status" == "not charging" ]]
			return
		fi
	done

	return 1
}

external_monitor_active() {
	hyprctl monitors -j 2>/dev/null | jq -e '.[] | select(.disabled == false and .name != "eDP-1")' >/dev/null
}

log() {
	logger -t "$log_tag" "$1"
}

gpu_is_on() {
	[[ -n "$(lspci -s 01:00.0 2>/dev/null)" ]]
}

sleep 3

if ! battery_is_discharging; then
	log "Skipping resume GPU power-off because the laptop is not on battery."
	exit 0
fi

if external_monitor_active; then
	log "Skipping resume GPU power-off because an external monitor is active."
	exit 0
fi

if ! gpu_is_on; then
	log "GPU already removed after resume."
	exit 0
fi

for attempt in $(seq 1 "$max_attempts"); do
	if "$script_dir/off-safe.sh" --quiet; then
		log "GPU powered off on resume attempt ${attempt}."
		exit 0
	fi

	if ! gpu_is_on; then
		log "GPU disappeared after failed attempt ${attempt}; treating as success."
		exit 0
	fi

	log "GPU still on after resume attempt ${attempt}; retrying."
	sleep "$sleep_between"
done

"$notice" "GPU Manager" "NVIDIA GPU stayed powered on after resume" "󰢮" "warning" 4500
log "GPU remained on after all resume retries."
exit 1
