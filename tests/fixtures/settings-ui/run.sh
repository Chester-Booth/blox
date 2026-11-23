#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reference_dir="${BLOX_REFERENCE_DIR:-$repo/../plans/blox-phase-4/unified-settings-and-themes/qml-mocks/reference-split}"
preview_root="$(mktemp -d /tmp/blox-settings-ui-XXXXXX)"
trap 'rm -rf "$preview_root"' EXIT
mkdir -p "$preview_root/config" "$preview_root/state" "$preview_root/data" "$preview_root/host"
mkdir -p "$preview_root/bin"
# A visual fixture must never change the live compositor or share its preview journal.
cat > "$preview_root/bin/hyprctl" <<'PY'
#!/usr/bin/env python3
import json
import sys

arguments = sys.argv[1:]
if arguments[:1] == ["status"]:
    print(json.dumps({"configProvider": "lua"}))
elif arguments[:1] == ["getoption"]:
    option = arguments[1]
    value = {"gradient": "ff000000 0deg"} if "col." in option or option.endswith("shadow:color") else {"float": 1} if option.endswith("opacity") else {"int": 0}
    print(json.dumps({"set": True, **value}))
elif arguments[:1] in (["eval"], ["--batch"], ["reload"]):
    print("ok")
else:
    sys.exit(1)
PY
chmod +x "$preview_root/bin/hyprctl"
export PATH="$preview_root/bin:$PATH"
export BLOX_HYPRLAND_PREVIEW_STATE="$preview_root/state/hyprland-preview.json"
cp "${BLOX_TEST_SHELL:-$repo/tests/fixtures/settings-ui/shell.qml}" "$preview_root/host/shell.qml"
sed -e 's#import "qs/shared" as Shared#import qs.shared as Shared#' -e "s#\"fixtures/#\"file://$reference_dir/fixtures/#g" "$reference_dir/MockState.qml" > "$preview_root/host/MockState.qml"
for module in modules services shared assets scripts popouts; do
    if [[ "${BLOX_TEST_SNAPSHOT:-0}" == 1 ]]; then
        cp -a "$repo/shell/$module" "$preview_root/host/$module"
    else
        ln -s "$repo/shell/$module" "$preview_root/host/$module"
    fi
done
ln -s "$repo/themes" "$preview_root/themes"
# Preserve native picker styling while keeping Blox writes isolated.
original_config="${XDG_CONFIG_HOME:-$HOME/.config}"
for gtk_version in gtk-3.0 gtk-4.0; do
    if [[ -d "$original_config/$gtk_version" ]]; then
        cp -RL "$original_config/$gtk_version" "$preview_root/config/"
    fi
done
export XDG_CONFIG_HOME="$preview_root/config" XDG_STATE_HOME="$preview_root/state" XDG_DATA_HOME="$preview_root/data"
export BLOX_USER_DATA_DIR="$preview_root/data/blox-user" BLOX_DATA_DIR="$repo/themes"
if [[ "${BLOX_TEST_SEEDED:-0}" == 1 ]]; then
    python3 "$repo/tests/fixtures/settings-ui/seed.py" "$reference_dir"
fi
# Use the approved visual tokens inside the isolated state root.
reference="$reference_dir/fixtures"
if [[ -d "$reference/state/blox" ]]; then
    cp -a "$reference/state/blox" "$preview_root/state/"
fi
if [[ "${BLOX_TEST_SEEDED:-0}" == 1 ]]; then
    python3 - "$preview_root/state/blox/theme/current/hypr/wallpaper.json" "$reference_dir" <<'PYDATA'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); value = json.loads(p.read_text())
value['path'] = str(Path(sys.argv[2]) / 'fixtures/wallpapers/blox-panel.png')
p.write_text(json.dumps(value))
PYDATA
fi
export QML_XHR_ALLOW_FILE_READ=1
export QML2_IMPORT_PATH="$preview_root/host" QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
quickshell -p "$preview_root/host/shell.qml"
