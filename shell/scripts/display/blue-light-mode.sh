#!/usr/bin/env bash
# Compatibility client. The loaded owner serialises mode changes.
set -euo pipefail
script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# == 0 ]]; then
    exec "$script_root/bloxctl.py" night-light restore --json
fi
exec "$script_root/bloxctl.py" night-light set "$1" --json
