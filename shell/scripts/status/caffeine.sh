#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell"
state_file="$state_dir/caffeine.json"
inhibit_unit="blox-caffeine.service"

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
	local deadline mode active remaining label class tooltip hypridle_running inhibited reconciled
	local capability_available capability_ready capability_change capability_permission capability_reason
	deadline="0"
	mode="off"
	reconciled=false
	capability_available=true
	capability_ready=true
	capability_change=true
	capability_permission="granted"
	capability_reason=""
	if ! command -v hypridle >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemd-inhibit >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
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

	if [[ "$capability_available" == "true" ]] && systemctl --user is-active --quiet "$inhibit_unit"; then
		inhibited=true
	else
		inhibited=false
	fi

	if [[ "$active" == "true" ]]; then
		if [[ "$inhibited" == "true" ]]; then
			tooltip+=$'\nHypridle paused'
		elif [[ "$hypridle_running" == "true" ]]; then
			class="warning"
			tooltip+=$'\nWarning: Awake inhibitor is not active'
		else
			class="warning"
			tooltip+=$'\nWarning: Hypridle is not running'
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
		--argjson inhibitActive "$inhibited" \
		--argjson reconciled "$reconciled" \
		'{icon:$icon,class:$class,mode:$mode,label:$label,tooltip:$tooltip,active:$active,deadline:$deadline,remaining:$remaining,hypridleRunning:$hypridleRunning,inhibitActive:$inhibitActive,reconciled:$reconciled}')"
	emit_status "$payload" "$capability_available" "$capability_ready" "$capability_change" "$capability_permission" "$capability_reason"
}

inhibit_start() {
	local duration="${1:-infinity}"

	systemctl --user start hypridle.service >/dev/null 2>&1
	if systemctl --user is-active --quiet "$inhibit_unit"; then
		return 0
	fi
	systemd-run --user --unit="${inhibit_unit%.service}" --collect --quiet \
		systemd-inhibit --what=idle --who=Blox --why="Awake mode" --mode=block sleep "$duration" >/dev/null 2>&1
}

inhibit_stop() {
	systemctl --user stop "$inhibit_unit" >/dev/null 2>&1 || true
}

reconcile() {
	local deadline=0

	if [[ -f "$state_file" ]]; then
		deadline="$(jq -r '.deadline // 0' "$state_file" 2>/dev/null || echo 0)"
	fi

	if [[ "$deadline" == "-1" ]]; then
		inhibit_start infinity
		return $?
	fi

	if [[ "$deadline" =~ ^[0-9]+$ ]] && ((deadline > $(now))); then
		inhibit_start "$((deadline - $(now)))"
		return $?
	fi

	if [[ -f "$state_file" ]]; then
		rm -f "$state_file"
	fi
	inhibit_stop
}

set_awake() {
	local duration="$1"
	local mode="$2"
	local deadline inhibit_duration

	mkdir -p "$state_dir"

	if [[ "$duration" == "indefinite" ]]; then
		deadline=-1
		inhibit_duration=infinity
	else
		deadline=$(($(now) + duration))
		inhibit_duration="$duration"
	fi

	jq -nc --argjson deadline "$deadline" --arg mode "$mode" '{deadline:$deadline,mode:$mode}' >"$state_file"
	inhibit_stop
	inhibit_start "$inhibit_duration"

	if [[ "$deadline" != "-1" ]]; then
		(
			sleep "$duration"
			current="$(jq -r '.deadline // 0' "$state_file" 2>/dev/null || echo 0)"
			if [[ "$current" == "$deadline" ]]; then
				rm -f "$state_file"
				inhibit_stop
			fi
		) >/dev/null 2>&1 &
	fi
}

turn_off() {
	rm -f "$state_file"
	inhibit_stop
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
reconcile)
	reconcile
	;;
*)
	echo "usage: $0 [status|30m|1h|indefinite|off|reconcile]" >&2
	exit 2
	;;
esac
