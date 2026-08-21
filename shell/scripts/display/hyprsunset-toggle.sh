#!/usr/bin/env bash
set -euo pipefail

state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell"
state_file="$state_dir/blue-light-mode"
blue_light_osd="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/blox/scripts/osd/blue-light.sh"
mkdir -p "$state_dir"

if pgrep -x hyprsunset >/dev/null; then
	echo "off" >"$state_file"
	pkill -x hyprsunset
	"$blue_light_osd" "off"
else
	echo "on" >"$state_file"
	hyprsunset >/dev/null 2>&1 &
	"$blue_light_osd" "on"
fi
