#!/usr/bin/env bash
# Private native adapter. Public callers use the loaded blox action owner.
set -euo pipefail
script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
brightness-set)
 device="${BRIGHTNESS_DEVICE:-}"
 [[ -n "$device" ]] || device="$("$script_root/status/brightness-device.sh")"
 [[ -n "$device" ]] || exit 1
 brightnessctl -q -d "$device" set "${2:?}%"
 percent="$(brightnessctl -d "$device" -m | awk -F, '{gsub(/%/, "", $4); print $4}')"
 if [[ "$percent" =~ ^[0-9]+$ ]]; then
  # The loaded provider publishes read-back and OSD feedback in process.
  printf '%s\n' "$percent"
 else
  exit 1
 fi
 ;;
touchpad-set)
 enabled="${2:-}"
 [[ "$enabled" == true || "$enabled" == false ]] || exit 2
 device="${TOUCHPAD_DEVICE:-}"
 [[ -n "$device" ]] || device="$("$script_root/status/touchpad-device.sh" | head -n1)"
 [[ "$device" =~ ^[a-zA-Z0-9_.:-]+$ ]] || exit 1
 hyprctl eval "hl.device({ name = \"$device\", enabled = $enabled })" >/dev/null
 state_file="${XDG_RUNTIME_DIR:-$HOME/.cache}/quickshell-touchpad-enabled"
 mkdir -p "$(dirname "$state_file")"
 printf '%s\n' "$enabled" >"$state_file"
 "$script_root/ipc.sh" osd touchpad "$enabled" >/dev/null 2>&1 || true
 ;;
profile-set)
 case "${2:-}" in performance|balanced|quiet) ;; *) exit 2;; esac
 asusctl profile set "$2"
 "$script_root/osd/fan-profile.sh" "$2"
 ;;
fan-curves-set)
 case "${2:-}" in on) enabled=true;; off) enabled=false;; *) exit 2;; esac
 profile="$(asusctl profile get | sed -n 's/^Active profile:[[:space:]]*//p' | head -n1)"
 [[ -n "$profile" ]] || exit 1
 exec asusctl fan-curve --mod-profile "$profile" --enable-fan-curves "$enabled"
 ;;
*) exit 2;;
esac
