#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell"
state_file="$state_dir/caffeine.json"

now() {
	date +%s
}

duration_label() {
	local seconds="$1"
	local hours mins

	hours=$((seconds / 3600))
	mins=$(((seconds % 3600) / 60))
	seconds=$((seconds % 60))

	if ((hours > 0)); then
		printf "%dh %02dm %02ds" "$hours" "$mins" "$seconds"
	elif ((mins > 0)); then
		printf "%dm %02ds" "$mins" "$seconds"
	else
		printf "%ds" "$seconds"
	fi
}

json_status() {
	local deadline mode active remaining label class tooltip hypridle_running reconciled
	local capability_available capability_ready capability_change capability_permission capability_reason
	deadline="0"
	mode="off"
	reconciled=false
	capability_available=true
	capability_ready=true
	capability_change=true
	capability_permission="granted"
	capability_reason=""
	if ! command -v hypridle >/dev/null 2>&1; then
		capability_available=false
		capability_ready=false
		capability_change=false
		capability_permission="unknown"
		capability_reason="command-unavailable"
	fi

	if [[ -f "$state_file" ]]; then
		deadline="$(jq -r '.deadline // 0' "$state_file" 2>/dev/null || echo 0)"
		mode="$(jq -r '.mode // "off"' "$state_file" 2>/dev/null || echo off)"
	fi

	if [[ "$deadline" == "-1" ]]; then
		active=true
		remaining=-1
		mode="indefinite"
		label="Indefinite"
		class="active"
		tooltip="Awake indefinitely"
	elif [[ "$deadline" =~ ^[0-9]+$ ]] && ((deadline > $(now))); then
		active=true
		remaining=$((deadline - $(now)))
		class="active"
		label="$(duration_label "$remaining")"
		tooltip="Awake for $label"
	else
		active=false
		remaining=0
		mode="off"
		label="Off"
		class="idle"
		tooltip="Hypridle running"
	fi

	if [[ "$capability_available" == "true" ]] && pgrep -x hypridle >/dev/null 2>&1; then
		hypridle_running=true
	else
		hypridle_running=false
	fi

	if [[ "$active" == "true" ]]; then
		if [[ "$hypridle_running" == "true" ]]; then
			class="warning"
			tooltip+=$'\nWarning: Hypridle is still running'
		else
			tooltip+=$'\nHypridle paused'
		fi
	else
		if [[ "$hypridle_running" == "true" ]]; then
			tooltip+=$'\nHypridle active'
		else
			class="warning"
			tooltip+=$'\nWarning: Hypridle is not running'
		fi
	fi

	payload="$(jq -nc \
		--arg icon "󰅶" \
		--arg class "$class" \
		--arg mode "$mode" \
		--arg label "$label" \
		--arg tooltip "$tooltip" \
		--argjson active "$active" \
		--argjson deadline "$deadline" \
		--argjson remaining "$remaining" \
		--argjson hypridleRunning "$hypridle_running" \
		--argjson reconciled "$reconciled" \
		'{icon:$icon,class:$class,mode:$mode,label:$label,tooltip:$tooltip,active:$active,deadline:$deadline,remaining:$remaining,hypridleRunning:$hypridleRunning,reconciled:$reconciled}')"
	emit_status "$payload" "$capability_available" "$capability_ready" "$capability_change" "$capability_permission" "$capability_reason"
}

set_awake() {
	local duration="$1"
	local mode="$2"
	local deadline

	mkdir -p "$state_dir"
	pkill -x hypridle >/dev/null 2>&1 || true

	if [[ "$duration" == "indefinite" ]]; then
		deadline=-1
	else
		deadline=$(($(now) + duration))
	fi

	jq -nc --argjson deadline "$deadline" --arg mode "$mode" '{deadline:$deadline,mode:$mode}' >"$state_file"

	if [[ "$deadline" != "-1" ]]; then
		(
			sleep "$duration"
			current="$(jq -r '.deadline // 0' "$state_file" 2>/dev/null || echo 0)"
			if [[ "$current" == "$deadline" ]]; then
				rm -f "$state_file"
			if command -v hypridle >/dev/null 2>&1 && ! pgrep -x hypridle >/dev/null 2>&1; then
					hypridle >/dev/null 2>&1 &
				fi
			fi
		) >/dev/null 2>&1 &
	fi
}

turn_off() {
	rm -f "$state_file"
	if command -v hypridle >/dev/null 2>&1 && ! pgrep -x hypridle >/dev/null 2>&1; then
		hypridle >/dev/null 2>&1 &
	fi
}

case "${1:-status}" in
status)
	json_status
	;;
30m)
	set_awake 1800 30m
	json_status
	;;
1h)
	set_awake 3600 1h
	json_status
	;;
indefinite)
	set_awake indefinite indefinite
	json_status
	;;
off)
	turn_off
	json_status
	;;
*)
	echo "usage: $0 [status|30m|1h|indefinite|off]" >&2
	exit 2
	;;
esac
