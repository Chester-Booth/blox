#!/usr/bin/env bash
set -euo pipefail

# The theme API must work from a git checkout AND the installed tree, so
# resolve the product root from this script's location: shell/scripts/theme
# sits two levels below a root that also contains themes/.
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$script_dir/../../.." && pwd -P)

# Fast native read-only path for `list --json` and `show <id> --json`.
# Falls back to Python themectl for inline JSON, invalid themes, or missing binary.
bloxd_bin="$root/shell/native/qml/Blox/Services/bloxd"
if [ ! -x "$bloxd_bin" ]; then
	bloxd_bin="${BLOX_INSTALL_ROOT:-${HOME}/.local/share/blox}/shell/native/qml/Blox/Services/bloxd"
fi
if [ -x "$bloxd_bin" ]; then
	if [ "$#" -eq 2 ] && [ "$1" = "list" ] && [ "$2" = "--json" ]; then
		if "$bloxd_bin" theme list --json 2>/dev/null; then
			exit 0
		fi
	elif [ "$#" -eq 3 ] && [ "$1" = "show" ] && [ "$3" = "--json" ] && [ "${2#\{}" = "$2" ]; then
		if "$bloxd_bin" theme show "$2" --json 2>/dev/null; then
			exit 0
		fi
	fi
fi

if [ -f "$root/themes/bin/themectl" ]; then
	exec "$root/themes/bin/themectl" "$@"
fi
exec "${BLOX_INSTALL_ROOT:-${HOME}/.local/share/blox}/themes/bin/themectl" "$@"
