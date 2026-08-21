#!/usr/bin/env bash
set -euo pipefail

title=${1:?window title required}
window_width=${2:?window width required}
window_height=${3:?window height required}
screen_name=${4:?screen name required}
popup_x=${5:?popup x required}
popup_y=${6:?popup y required}
popup_width=${7:?popup width required}

address=""
for _ in 1 2 3 4 5; do
	address=$(hyprctl clients -j | jq -r --arg title "$title" '[.[] | select(.title == $title)] | last | .address // empty')
	[[ -n "$address" ]] && break
	sleep 0.04
done
[[ -n "$address" ]] || exit 1

read -r monitor_x monitor_y monitor_width monitor_height < <(
	hyprctl monitors -j | jq -r --arg name "$screen_name" '
        [.[] | select(.name == $name)][0]
        | [.x, .y, .width, .height] | @tsv'
)

gap=8
popup_left=$((monitor_x + popup_x))
popup_top=$((monitor_y + popup_y))
popup_right=$((popup_left + popup_width))

if ((popup_right + gap + window_width <= monitor_x + monitor_width - gap)); then
	target_x=$((popup_right + gap))
else
	target_x=$((popup_left - gap - window_width))
fi
((target_x < monitor_x + gap)) && target_x=$((monitor_x + gap))

target_y=$popup_top
((target_y + window_height > monitor_y + monitor_height - gap)) && target_y=$((monitor_y + monitor_height - window_height - gap))
((target_y < monitor_y + gap)) && target_y=$((monitor_y + gap))

hyprctl dispatch "hl.dsp.window.float({ action = \"on\", window = \"address:${address}\" })"
hyprctl dispatch "hl.dsp.window.resize({ x = ${window_width}, y = ${window_height}, relative = false, window = \"address:${address}\" })"
hyprctl dispatch "hl.dsp.window.move({ x = ${target_x}, y = ${target_y}, relative = false, window = \"address:${address}\" })"
hyprctl dispatch "hl.dsp.window.pin({ action = \"on\", window = \"address:${address}\" })"
