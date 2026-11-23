#!/usr/bin/env bash
set -u

script_root="${QUICKSHELL_SCRIPT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
# Shared system actions go through the loaded owner. Never retry a denied action
# with a native command. Keyboard/camera controls below remain separate adapters.
case "${1:-}" in
volume-up) exec "$script_root/bloxctl.py" audio adjust-volume "${2:-2}" --json;;
volume-down) exec "$script_root/bloxctl.py" audio adjust-volume "-${2:-2}" --json;;
volume-set) exec "$script_root/bloxctl.py" audio set-volume "${2:-0}" --json;;
volume-mute) exec "$script_root/bloxctl.py" audio toggle-mute --json;;
mic-mute) exec "$script_root/bloxctl.py" audio toggle-mic --json;;
brightness-up) exec "$script_root/bloxctl.py" brightness adjust "${2:-2}" --json;;
brightness-down) exec "$script_root/bloxctl.py" brightness adjust "-${2:-2}" --json;;
brightness-set) exec "$script_root/bloxctl.py" brightness set "${2:-0}" --json;;
touchpad-on) exec "$script_root/bloxctl.py" touchpad set on --json;;
touchpad-off) exec "$script_root/bloxctl.py" touchpad set off --json;;
touchpad-toggle) exec "$script_root/bloxctl.py" touchpad toggle --json;;
esac

keyboard_device="${KEYBOARD_BRIGHTNESS_DEVICE:-asus::kbd_backlight}"
camera_device="${CAMERA_DEVICE:-asus::camera}"
camera_usb_id="${CAMERA_USB_ID:-3277:0010}"
camera_authorized_override="${CAMERA_AUTHORIZED_FILE:-}"
caps_led="${CAPS_LOCK_LED:-}"
upower_kbd_service="org.freedesktop.UPower"
upower_kbd_path="/org/freedesktop/UPower/KbdBacklight"
upower_kbd_interface="org.freedesktop.UPower.KbdBacklight"

ipc() {
	"$script_root/ipc.sh" osd "$@" >/dev/null 2>&1 || true
}

keyboard_percent() {
	local current max
	if current="$(upower_keyboard_get)" && max="$(upower_keyboard_max)" && [[ "$max" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
		printf '%s\n' "$(((current * 100 + max / 2) / max))"
		return
	fi

	current="$(brightnessctl -d "$keyboard_device" g 2>/dev/null || printf '0')"
	max="$(brightnessctl -d "$keyboard_device" m 2>/dev/null || printf '1')"
	if [[ "$max" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
		printf '%s\n' "$(((current * 100 + max / 2) / max))"
	else
		printf '0\n'
	fi
}

upower_keyboard_get() {
	gdbus call --system \
		--dest "$upower_kbd_service" \
		--object-path "$upower_kbd_path" \
		--method "$upower_kbd_interface.GetBrightness" 2>/dev/null |
		awk -F'[(), ]+' '{print $2}'
}

upower_keyboard_max() {
	gdbus call --system \
		--dest "$upower_kbd_service" \
		--object-path "$upower_kbd_path" \
		--method "$upower_kbd_interface.GetMaxBrightness" 2>/dev/null |
		awk -F'[(), ]+' '{print $2}'
}

upower_keyboard_set() {
	local value="$1"

	gdbus call --system \
		--dest "$upower_kbd_service" \
		--object-path "$upower_kbd_path" \
		--method "$upower_kbd_interface.SetBrightness" "$value" >/dev/null 2>&1
}

keyboard_change() {
	local delta="$1"
	local current max next

	if current="$(upower_keyboard_get)" && max="$(upower_keyboard_max)" && [[ "$max" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ && "$max" -gt 0 ]]; then
		next=$((current + delta))
		((next < 0)) && next=0
		((next > max)) && next=max
		upower_keyboard_set "$next" || return 1
		return 0
	fi

	if ((delta > 0)); then
		brightnessctl -d "$keyboard_device" set "+$delta"
	else
		brightnessctl -d "$keyboard_device" set "$((-delta))-"
	fi
}

caps_enabled() {
	local led state

	if [[ -n "$caps_led" && -r "$caps_led" ]]; then
		read -r state <"$caps_led"
		[[ "$state" == "1" ]] && printf 'true\n' || printf 'false\n'
		return
	fi

	for led in /sys/class/leds/*::capslock/brightness; do
		[[ -r "$led" ]] || continue
		read -r state <"$led"
		if [[ "$state" == "1" ]]; then
			printf 'true\n'
			return
		fi
	done

	printf 'false\n'
}

show_keyboard() {
	ipc keyboard "$(keyboard_percent)"
}

camera_authorized_file() {
	local authorized device usb_id

	if [[ -n "$camera_authorized_override" ]]; then
		[[ -e "$camera_authorized_override" ]] || return 1
		printf '%s\n' "$camera_authorized_override"
		return
	fi

	for authorized in /sys/bus/usb/devices/*/authorized; do
		[[ -r "$authorized" ]] || continue
		device="${authorized%/authorized}"
		[[ -r "$device/idVendor" && -r "$device/idProduct" ]] || continue
		usb_id="$(<"$device/idVendor")":"$(<"$device/idProduct")"
		[[ "$usb_id" == "$camera_usb_id" ]] || continue
		printf '%s\n' "$authorized"
		return
	done

	return 1
}

camera_enabled() {
	local authorized state

	authorized="$(camera_authorized_file)" || {
		printf 'false\n'
		return 1
	}
	read -r state <"$authorized" || {
		printf 'false\n'
		return 1
	}
	[[ "$state" == "1" ]] && printf 'true\n' || printf 'false\n'
}

set_camera() {
	local enabled="$1"
	local authorized value led_value

	[[ "$enabled" == "true" || "$enabled" == "false" ]] || return 1
	authorized="$(camera_authorized_file)" || {
		printf 'camera USB device %s was not found\n' "$camera_usb_id" >&2
		return 1
	}
	[[ -w "$authorized" ]] || {
		printf 'camera control %s is not writable; install the camera udev rule\n' "$authorized" >&2
		return 1
	}

	value=0
	led_value=1
	if [[ "$enabled" == "true" ]]; then
		value=1
		led_value=0
	fi
	printf '%s\n' "$value" >"$authorized" || return 1
	brightnessctl -q -d "$camera_device" set "$led_value" >/dev/null 2>&1 || true
}

show_camera() {
	ipc camera "$(camera_enabled)"
}

show_caps() {
	ipc caps "$(caps_enabled)"
}

case "${1:-}" in
keyboard-up)
	keyboard_change "${2:-1}" || exit 1
	show_keyboard
	;;
keyboard-down)
	keyboard_change "-${2:-1}" || exit 1
	show_keyboard
	;;
keyboard-toggle)
	if [[ "$(keyboard_percent)" -gt 0 ]]; then
		keyboard_change -100 || exit 1
	else
		keyboard_change 100 || exit 1
	fi
	show_keyboard
	;;
camera-toggle)
	camera_state="$(camera_enabled)" || exit 1
	if [[ "$camera_state" == "true" ]]; then
		set_camera false || exit 1
	else
		set_camera true || exit 1
	fi
	show_camera
	;;
caps)
	sleep 0.12
	show_caps
	;;
*)
	printf 'usage: %s {volume-up|volume-down|volume-mute|mic-mute|brightness-up|brightness-down|brightness-set|keyboard-up|keyboard-down|keyboard-toggle|camera-toggle|touchpad-toggle|touchpad-on|touchpad-off|caps} [amount]\n' "$0" >&2
	exit 2
	;;
esac
