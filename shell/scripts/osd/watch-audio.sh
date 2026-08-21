#!/usr/bin/env bash
set -u

runtime_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quickshell}"
lock_file="$runtime_dir/audio-osd.lock"
mkdir -p "$runtime_dir"
exec 9>"$lock_file"
flock -n 9 || exit 75

audio_state() {
	local volume muted

	volume="$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | awk -F'/' 'NR == 1 { gsub(/[ %]/, "", $2); print $2 }')"
	muted="$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2 == "yes" ? "true" : "false"}')"
	[[ "$volume" =~ ^[0-9]+$ ]] || return 1
	[[ "$muted" == "true" || "$muted" == "false" ]] || return 1
	printf '%s %s\n' "$volume" "$muted"
}

previous="$(audio_state || true)"
monitor_pid=""
watchdog_pid=""
parent_pid="$PPID"
shell_pid="$$"

cleanup() {
	if [[ -n "$monitor_pid" ]]; then
		kill "$monitor_pid" 2>/dev/null || true
		wait "$monitor_pid" 2>/dev/null || true
	fi
	if [[ -n "$watchdog_pid" ]]; then
		kill "$watchdog_pid" 2>/dev/null || true
		wait "$watchdog_pid" 2>/dev/null || true
	fi
}

trap cleanup EXIT INT TERM

(
	while kill -0 "$parent_pid" 2>/dev/null; do
		sleep 1
	done
	kill -TERM "$shell_pid" 2>/dev/null || true
) &
watchdog_pid="$!"

pactl subscribe 2>/dev/null > >(
	while IFS= read -r event; do
		case "$event" in
		*" on sink "* | *" on server "*) ;;
		*) continue ;;
		esac

		state="$(audio_state || true)"
		[[ -n "$state" && "$state" != "$previous" ]] || continue
		previous="$state"
		read -r volume muted <<<"$state"
		printf '{"volume":%d,"muted":%s}\n' "$volume" "$muted"
	done
) &
monitor_pid="$!"
wait "$monitor_pid"
