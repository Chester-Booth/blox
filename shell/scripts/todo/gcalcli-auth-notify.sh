#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

action=$(notify-send \
	--app-name="gcalcli" \
	--urgency=critical \
	--action=reauth="Re-authenticate" \
	"Google Calendar auth expired" \
	"Click Re-authenticate to run gcalcli init. The OAuth client details will be filled automatically." 2>/dev/null || true)

if [ "$action" = "reauth" ]; then
	exec "$SCRIPT_DIR/gcalcli-init-fix.sh"
fi
