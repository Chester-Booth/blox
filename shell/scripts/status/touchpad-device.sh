#!/usr/bin/env bash
set -u

if [[ -n "${TOUCHPAD_DEVICE:-}" ]]; then
	printf '%s\n' "$TOUCHPAD_DEVICE"
	exit 0
fi

command -v hyprctl >/dev/null 2>&1 || exit 127
command -v jq >/dev/null 2>&1 || exit 127

devices="$(hyprctl devices -j 2>/dev/null)" || exit 1
jq -r '.mice[]?.name // empty | select(test("touchpad|trackpad"; "i"))' <<<"$devices"
