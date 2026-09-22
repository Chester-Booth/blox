#!/usr/bin/env bash
set -u

runtime_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quickshell}"
lock_file="$runtime_dir/keyboard-backlight.lock"
mkdir -p "$runtime_dir"
exec 9>"$lock_file"
flock -n 9 || exit 75

keyboard_device="${KEYBOARD_BRIGHTNESS_DEVICE:-}"
if [[ -z "$keyboard_device" ]]; then
	for led_dir in /sys/class/leds/*kbd_backlight; do
		[[ -d "$led_dir" ]] || continue
		keyboard_device="${led_dir##*/}"
		break
	done
fi
[[ -z "$keyboard_device" || "$keyboard_device" =~ ^[[:alnum:]_.:-]+$ ]] || exit 0

brightness_file="/sys/class/leds/$keyboard_device/brightness"
max_file="/sys/class/leds/$keyboard_device/max_brightness"
use_sysfs=false
if [[ -n "$keyboard_device" && -r "$brightness_file" && -r "$max_file" ]]; then
	read -r max <"$max_file" || exit 0
	read -r previous <"$brightness_file" || exit 0
	[[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 && "$previous" =~ ^[0-9]+$ ]] || exit 0
	use_sysfs=true
else
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
fi

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

trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

(
	while kill -0 "$parent_pid" 2>/dev/null; do
		sleep 1
	done
	kill -TERM "$shell_pid" 2>/dev/null || true
) &
watchdog_pid="$!"

if [[ "$use_sysfs" == true ]]; then
	# Some firmware changes the LED without sending a UPower brightness signal.
	while kill -0 "$parent_pid" 2>/dev/null; do
		if ! read -r current <"$brightness_file"; then
			break
		fi
		if [[ "$current" =~ ^[0-9]+$ && "$current" != "$previous" ]]; then
			printf '{"value":%d,"max":%d}\n' "$current" "$max"
			previous="$current"
		fi
		sleep 0.2
	done
else
	gdbus monitor --system --dest "$service" --object-path "$path" 2>/dev/null > >(
		awk -v max="$max" '
			/BrightnessChanged(WithSource)?/ {
				value = $0
				sub(/^.*BrightnessChanged(WithSource)? \(/, "", value)
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
fi
