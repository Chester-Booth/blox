#!/usr/bin/env bash
set -euo pipefail

state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell"
state_file="$state_dir/blue-light-mode"
generated_config="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/generated/hyprsunset.conf"
runtime_config_home="$state_dir/hyprsunset"
config_file="$runtime_config_home/hypr/hyprsunset.conf"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../display" && pwd)"
blue_light_osd="$script_dir/../osd/blue-light.sh"
mode="${1:-}"
quiet="${2:-}"
if [[ -n "$quiet" && "$quiet" != "--quiet" ]]; then
    echo "Usage: $0 on|auto|off [--quiet]" >&2
    exit 2
fi

if [[ -z "$mode" ]] && [[ -r "$state_file" ]]; then
	read -r mode <"$state_file"
fi
mode="${mode:-auto}"

if [[ "$mode" == "status" ]]; then
    bloxd_bin="$script_dir/../../native/qml/Blox/Services/bloxd"
    if [[ -z "${BLOX_NO_BLOXD:-}" && -x "$bloxd_bin" ]]; then
        exec "$bloxd_bin" status night-light
    fi
    saved_mode="auto"
    [[ ! -r "$state_file" ]] || read -r saved_mode <"$state_file"
    case "$saved_mode" in on|off|auto) ;; *) saved_mode=auto ;; esac
    available=false
    command -v hyprsunset >/dev/null && available=true
    active=false
    if pgrep -x hyprsunset >/dev/null; then
        active="$("$script_dir/blue-light-active.sh")"
    fi
    printf '{"mode":"%s","active":%s,"available":%s}\n' "$saved_mode" "$active" "$available"
    exit 0
fi

mkdir -p "$state_dir" "$(dirname "$config_file")" "$(dirname "$generated_config")"

restart_filter() {
	pkill -x hyprsunset >/dev/null 2>&1 || true
	for _ in {1..20}; do
		pgrep -x hyprsunset >/dev/null 2>&1 || break
		sleep 0.05
	done
	XDG_CONFIG_HOME="$runtime_config_home" hyprsunset >/dev/null 2>&1 &
}

write_config() {
	local selected_mode="$1"

	mkdir -p "$(dirname "$config_file")"

	case "$selected_mode" in
	on)
		cat >"$config_file" <<'EOF'
max-gamma = 150

profile {
    time = 00:00
    temperature = 4500
}
EOF
		;;
	off)
		cat >"$config_file" <<'EOF'
max-gamma = 150

profile {
    time = 00:00
    identity = true
}
EOF
		;;
	auto)
		cat >"$config_file" <<'EOF'
max-gamma = 150

profile {
    time = 07:00
    identity = true
}

profile {
    time = 18:00
    temperature = 6000
}

profile {
    time = 20:00
    temperature = 5500
}

profile {
    time = 22:00
    temperature = 4500
}
EOF
		;;
	esac

	cp "$config_file" "$generated_config"
}

case "$mode" in
on)
	echo "on" >"$state_file"
	write_config "on"
	restart_filter
	[[ "$quiet" == "--quiet" ]] || "$blue_light_osd" "on"
	;;
off | disable | disabled)
	echo "off" >"$state_file"
	write_config "off"
	restart_filter
	[[ "$quiet" == "--quiet" ]] || "$blue_light_osd" "off"
	;;
auto)
	echo "auto" >"$state_file"
	write_config "auto"
	restart_filter
	[[ "$quiet" == "--quiet" ]] || "$blue_light_osd" "auto"
	;;
*)
	echo "Usage: $0 on|auto|off" >&2
	exit 2
	;;
esac
