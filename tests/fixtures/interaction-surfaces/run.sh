#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture_root="$(mktemp -d /tmp/blox-interaction-surfaces-XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/config" "$fixture_root/state" "$fixture_root/data" "$fixture_root/host"
cp "${BLOX_INTERACTION_SHELL:-$repo/tests/fixtures/interaction-surfaces/shell.qml}" "$fixture_root/host/shell.qml"
for module in modules services shared popouts scripts assets; do
    ln -s "$repo/shell/$module" "$fixture_root/host/$module"
done
ln -s "$repo/themes" "$fixture_root/host/themes"
export QML2_IMPORT_PATH="$fixture_root/host:$repo/widgets/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export XDG_CONFIG_HOME="$fixture_root/config" XDG_STATE_HOME="$fixture_root/state" XDG_DATA_HOME="$fixture_root/data"
export BLOX_USER_DATA_DIR="$fixture_root/data/blox-user" BLOX_DATA_DIR="$repo/themes"
export QS_CONFIG_HOME="$fixture_root/config/quickshell"
export QML_XHR_ALLOW_FILE_READ=1
quickshell -p "$fixture_root/host/shell.qml"
