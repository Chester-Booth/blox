#!/usr/bin/env bash
set -euo pipefail
script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$script_root/bloxctl.py" night-light toggle --json
