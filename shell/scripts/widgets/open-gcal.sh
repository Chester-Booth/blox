#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

zen-browser calendar.google.com >/dev/null 2>&1 || true
hyprctl dispatch 'hl.dsp.focus({ workspace = 1 })' >/dev/null 2>&1 || true
"$SCRIPT_DIR/../todo/update-gcal-md.sh" >/dev/null 2>&1 || true
