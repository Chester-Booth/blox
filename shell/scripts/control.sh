#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
action="${1:-}"

case "$action" in
audio-toggle)
	exec "$script_dir/osd/control.sh" volume-mute
	;;
audio-set-silent)
	exec pactl set-sink-volume @DEFAULT_SINK@ "${2:-0}%"
	;;
mic-toggle)
	exec "$script_dir/osd/control.sh" mic-mute
	;;
mic)
	case "${2:-}" in
	open) pactl set-source-mute @DEFAULT_SOURCE@ 0 ;;
	muted) pactl set-source-mute @DEFAULT_SOURCE@ 1 ;;
	*)
		echo "usage: $0 mic open|muted" >&2
		exit 2
		;;
	esac
	exec "$script_dir/osd/control.sh" mic-show
	;;
brightness-set-silent)
	exec brightnessctl -q -d "${BRIGHTNESS_DEVICE:-amdgpu_bl1}" set "${2:-0}%"
	;;
wifi)
	case "${2:-}" in
	on | off) nmcli radio wifi "$2" ;;
	*)
		echo "usage: $0 wifi on|off" >&2
		exit 2
		;;
	esac
	;;
bluetooth-toggle)
	rfkill toggle bluetooth
	;;
bluetooth)
	case "${2:-}" in
	on) rfkill unblock bluetooth ;;
	off) rfkill block bluetooth ;;
	*)
		echo "usage: $0 bluetooth on|off" >&2
		exit 2
		;;
	esac
	;;
fan-profile)
	case "${2:-}" in
	performance | balanced | quiet)
		asusctl profile set "$2"
		"$script_dir/osd/fan-profile.sh" "$2"
		;;
	*)
		echo "usage: $0 fan-profile performance|balanced|quiet" >&2
		exit 2
		;;
	esac
	;;
*)
	echo "usage: $0 audio-toggle|audio-set-silent|mic-toggle|mic|brightness-set-silent|wifi|bluetooth-toggle|bluetooth|fan-profile" >&2
	exit 2
	;;
esac
