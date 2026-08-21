#!/usr/bin/env bash
set -u

runtime_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quickshell}"
lock_file="$runtime_dir/keyboard-backlight.lock"
mkdir -p "$runtime_dir"
exec 9>"$lock_file"
flock -n 9 || exit 75

service="org.freedesktop.UPower"
path="/org/freedesktop/UPower/KbdBacklight"
interface="org.freedesktop.UPower.KbdBacklight"

max="$(
	gdbus call --system \
		--dest "$service" \
		--object-path "$path" \
		--method "$interface.GetMaxBrightness" 2>/dev/null |
		awk -F'[(), ]+' '{print $2}'
)"

[[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || exit 0

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

gdbus monitor --system --dest "$service" --object-path "$path" 2>/dev/null > >(
	awk -v max="$max" '
		/BrightnessChangedWithSource/ {
			value = $0
			sub(/^.*BrightnessChangedWithSource \(/, "", value)
			sub(/,.*$/, "", value)
			if (value ~ /^[0-9]+$/) {
				printf("{\"value\":%d,\"max\":%d}\n", value, max)
				fflush()
			}
		}
	'
) &
monitor_pid="$!"
wait "$monitor_pid"
