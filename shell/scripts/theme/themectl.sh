#!/usr/bin/env bash
set -euo pipefail

script_path=$(readlink -f "${BASH_SOURCE[0]}")
repo_root=$(git -C "$(dirname "$script_path")" rev-parse --show-toplevel)
exec "$repo_root/themes/bin/themectl" "$@"
