#!/usr/bin/env bash
# Compatibility client for the running action owner.
set -euo pipefail
script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
audio-toggle) exec "$script_root/bloxctl.py" audio toggle-mute --json;;
audio-set-silent) exec "$script_root/bloxctl.py" audio set-volume "${2:-0}" --json;;
mic-toggle) exec "$script_root/bloxctl.py" audio toggle-mic --json;;
mic) exec "$script_root/bloxctl.py" audio set-mic "${2:-}" --json;;
brightness-set-silent) exec "$script_root/bloxctl.py" brightness set "${2:-0}" --json;;
wifi) exec "$script_root/bloxctl.py" network set-wifi "${2:-}" --json;;
bluetooth-toggle) exec "$script_root/bloxctl.py" bluetooth toggle-enabled --json;;
bluetooth) exec "$script_root/bloxctl.py" bluetooth set-enabled "${2:-}" --json;;
fan-profile) exec "$script_root/bloxctl.py" vendor set-profile "${2:-}" --json;;
fan-curves) exec "$script_root/bloxctl.py" vendor set-fan-curves "${2:-}" --json;;
*) echo 'Unknown control action' >&2; exit 2;;
esac
