#!/usr/bin/env bash
set -u

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
notice="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/blox/scripts/osd/notice.sh"
gpu_osd="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/blox/scripts/osd/gpu-mode.sh"
mode="${1:-}"
if (($# > 0)); then
	shift
fi

notifications_enabled=1
backend_args=()
for arg in "$@"; do
	case "$arg" in
	--quiet | --no-notify)
		notifications_enabled=0
		backend_args+=("$arg")
		;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

notify_mode() {
	if ((notifications_enabled)); then
		"$notice" "$@"
	fi
}

set_refresh() {
	local hz="$1"
	local icon="$2"

	if ! hyprctl eval "hl.monitor({ output = \"eDP-1\", mode = \"1920x1080@${hz}\", position = \"0x0\", scale = 1 })"; then
		notify_mode "Display mode" "Failed to switch the internal display to ${hz} Hz" "$icon" "critical" 4500
		return 1
	fi
}

require_battery_level() {
	local label="$1"
	local icon="$2"
	local battery_percent battery_status

	battery_percent="$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -n1)"
	battery_status="$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -n1)"
	if [[ "$battery_percent" =~ ^[0-9]+$ ]] && [[ "$battery_status" != "Charging" ]] && ((battery_percent < 50)); then
		notify_mode "$label" "Battery below 50% (${battery_percent}%)" "$icon" "critical" 4500
		return 1
	fi
}

case "$mode" in
gaming)
	require_battery_level "Gaming mode" "󰪫" || exit 1
	"$script_dir/on-safe.sh" "${backend_args[@]}" || exit $?
	set_refresh 144 "󰪫" || exit 1
	;;
performance)
	require_battery_level "Performance mode" "󰢮" || exit 1
	"$script_dir/on-safe.sh" "${backend_args[@]}" || exit $?
	set_refresh 60 "󰢮" || exit 1
	;;
high-refresh)
	require_battery_level "High refresh mode" "" || exit 1
	"$script_dir/off-safe.sh" "${backend_args[@]}" || exit $?
	set_refresh 144 "" || exit 1
	;;
eco)
	"$script_dir/off-safe.sh" "${backend_args[@]}" || exit $?
	set_refresh 60 "󰌪" || exit 1
	asusctl profile set Quiet || exit 1
	;;
*)
	echo "usage: $0 gaming|performance|high-refresh|eco [--quiet]" >&2
	exit 2
	;;
esac

if ((notifications_enabled)); then
	"$gpu_osd" "$mode"
fi
