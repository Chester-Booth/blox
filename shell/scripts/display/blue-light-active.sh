#!/usr/bin/env bash
set -u

state_file="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/blue-light-mode"
config_file="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/hyprsunset/hypr/hyprsunset.conf"

mode="auto"
[[ -r "$state_file" ]] && read -r mode <"$state_file"

case "$mode" in
on)
	printf 'true\n'
	exit 0
	;;
off | disable | disabled)
	printf 'false\n'
	exit 0
	;;
esac

if [[ ! -r "$config_file" ]]; then
	printf 'false\n'
	exit 0
fi

now_minutes="$(date +%H:%M | awk -F: '{print ($1 * 60) + $2}')"

awk -v now="$now_minutes" '
function minutes(value, parts) {
    split(value, parts, ":")
    return (parts[1] * 60) + parts[2]
}
function finish() {
    if (!in_profile || profile_time == "") {
        return
    }
    profile_minutes = minutes(profile_time)
    if (profile_minutes <= now) {
        selected_active = profile_active
        selected_seen = 1
    }
    last_active = profile_active
    last_seen = 1
}
/^[[:space:]]*profile[[:space:]]*\{/ {
    in_profile = 1
    profile_time = ""
    profile_active = 0
    next
}
in_profile && /^[[:space:]]*time[[:space:]]*=/ {
    value = $0
    sub(/.*=[[:space:]]*/, "", value)
    gsub(/[[:space:]]/, "", value)
    profile_time = value
    next
}
in_profile && /^[[:space:]]*temperature[[:space:]]*=/ {
    profile_active = 1
    next
}
in_profile && /^[[:space:]]*identity[[:space:]]*=[[:space:]]*true/ {
    profile_active = 0
    next
}
in_profile && /^[[:space:]]*\}/ {
    finish()
    in_profile = 0
    next
}
END {
    finish()
    active = selected_seen ? selected_active : last_active
    print active ? "true" : "false"
}
' "$config_file"
