#!/usr/bin/env bash
set -euo pipefail

# The package and source checkout both keep widgets beside shell.
script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BLOX_WIDGETS_ROOT="$(cd -- "$script_dir/../../../widgets" && pwd -P)"
export BLOX_WIDGETS_ROOT
widget_import_path="$(cd -- "$BLOX_WIDGETS_ROOT/qml" && pwd -P)"
native_import_path="$script_dir/../../native/qml"
if [[ ! -r "$native_import_path/Blox/Services/qmldir" || ! -r "$native_import_path/Blox/Services/libbloxservicesplugin.so" ]]; then
	echo 'Blox.Services is missing. Run make native-services in the source tree, then install or update Blox.' >&2
	exit 1
fi
export QML_IMPORT_PATH="$native_import_path:$widget_import_path${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"

# Quickshell reads QS_ICON_THEME at process start. Read the active generated
# value here so Apply can change shell icons after the existing deferred
# Quickshell restart, while an explicit environment value still wins.
state_home="$(printenv XDG_STATE_HOME || true)"
if [[ -z "$state_home" ]]; then
	state_home="$HOME/.local/state"
fi
theme_file="$state_home/blox/theme/current/quickshell/theme.json"
configured_icon_theme="$(printenv QS_ICON_THEME || true)"
if [[ -z "$configured_icon_theme" && -r "$theme_file" ]]; then
	icon_theme="$(jq -r '.icons.theme // empty' "$theme_file" 2>/dev/null || true)"
	if [[ -n "$icon_theme" ]]; then
		export QS_ICON_THEME="$icon_theme"
	fi
fi

# Run Quickshell directly as systemd's MainPID; systemd owns the cgroup lifecycle.
exec /usr/bin/quickshell "$@"
