#!/usr/bin/env bash
set -u

# Print discovered hardware backlight names. The first result is the default
# display device; LED devices are deliberately excluded.
list_backlights() {
	if command -v brightnessctl >/dev/null 2>&1; then
		brightnessctl -l 2>/dev/null | awk -F"'" "/class 'backlight'/ {print \$2}"
	fi

	for path in /sys/class/backlight/*; do
		[[ -d "$path" ]] || continue
		basename "$path"
	done
}

list_backlights | awk 'length($0) > 0 && !seen[$0]++'
