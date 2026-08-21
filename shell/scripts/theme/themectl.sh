#!/usr/bin/env bash
set -euo pipefail

# The theme API must work from a git checkout AND the installed tree, so
# resolve the product root from this script's location: shell/scripts/theme
# sits two levels below a root that also contains themes/.
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$script_dir/../../.." && pwd -P)
if [ -f "$root/themes/bin/themectl" ]; then
	exec "$root/themes/bin/themectl" "$@"
fi
exec "${BLOX_INSTALL_ROOT:-${HOME}/.local/share/blox}/themes/bin/themectl" "$@"
