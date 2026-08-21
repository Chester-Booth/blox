#!/usr/bin/env bash
set -u

# shellcheck source=../status/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../status" && pwd)/common.sh"

if ! command -v hyprctl >/dev/null 2>&1; then
	emit_status '{"workspace":null,"empty":false,"count":0}' false false false unknown "command-unavailable"
	exit 0
fi

workspace_json="$(hyprctl activeworkspace -j 2>/dev/null || true)"
workspace="$(jq -r '.id // empty' <<<"$workspace_json" 2>/dev/null || true)"

if ! [[ "$workspace" =~ ^-?[0-9]+$ ]]; then
	emit_status '{"workspace":null,"empty":false,"count":0}' true false false unknown "query-failed"
	exit 0
fi

clients_json="$(hyprctl clients -j 2>/dev/null || true)"
if ! jq -e 'type == "array"' <<<"$clients_json" >/dev/null 2>&1; then
	payload="$(jq -nc --argjson workspace "$workspace" '{workspace:$workspace,empty:false,count:0}')"
	emit_status "$payload" true false false unknown "query-failed"
	exit 0
fi

count="$(jq --argjson ws "$workspace" '[.[] | select(.workspace.id == $ws)] | length' <<<"$clients_json" 2>/dev/null || printf '0\n')"
[[ "$count" =~ ^[0-9]+$ ]] || count=0
payload="$(jq -nc --argjson workspace "$workspace" --argjson count "$count" '{workspace:$workspace,empty:($count == 0),count:$count}')"
emit_status "$payload" true true false not-required ""
