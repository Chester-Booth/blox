#!/usr/bin/env bash
# Feedback for an already observed microphone state. This never changes mute.
set -euo pipefail
script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
muted="${1:-}"
case "$muted" in
true) led=1; percent=0 ;;
false) led=0; percent=100 ;;
*) exit 2 ;;
esac
if command -v brightnessctl >/dev/null 2>&1; then
	brightnessctl -q -d "${MIC_LED_DEVICE:-platform::micmute}" set "$led" >/dev/null 2>&1 || true
fi
"$script_root/ipc.sh" osd mic "$percent" "$muted" >/dev/null 2>&1 || true
