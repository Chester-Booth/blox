#!/usr/bin/env bash
set -u

# This is an optional vendor owner. A missing asusctl command is a typed
# unavailable result, not a reason for the shell to fail.
# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

unavailable() {
	local reason="${1:-command-unavailable}"
	local payload
	payload="$(jq -nc --arg reason "$reason" '{
        vendor:"asusctl",
        profile:"unavailable",
        profiles:[],
        profileLabels:[],
        details:"Vendor performance provider unavailable",
        tooltip:"Vendor performance unavailable",
        errorCode:$reason
    }')"
	emit_status "$payload" false false false unknown "$reason"
}

if ! command -v asusctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
	unavailable
	exit 0
fi

profiles_raw="$(asusctl profile list 2>/dev/null)" || {
	unavailable "query-failed"
	exit 0
}
active_raw="$(asusctl profile get 2>/dev/null)" || {
	unavailable "query-failed"
	exit 0
}

profiles_json="$(printf '%s\n' "$profiles_raw" | awk 'NF { print tolower($0) }' | sed 's/[[:space:]]\+$//' | jq -Rsc 'split("\n") | map(select(length > 0) | gsub(" "; "-"))')"
profile_label="$(printf '%s\n' "$active_raw" | sed -n 's/^Active profile:[[:space:]]*//p' | head -n1)"
profile="$(printf '%s' "$profile_label" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/-/g')"

if [[ -z "$profile_label" ]]; then
	unavailable "malformed-status"
	exit 0
fi

profile_count="$(jq 'length' <<<"$profiles_json")"
if [[ "$profile_count" -gt 0 ]]; then
	capability_available=true
	capability_ready=true
	capability_can_change=true
	reason=""
else
	capability_available=true
	capability_ready=true
	capability_can_change=false
	reason="profile-unavailable"
fi

payload="$(jq -nc \
	--arg vendor "asusctl" \
	--arg profile "$profile" \
	--arg label "$profile_label" \
	--argjson profiles "$profiles_json" \
	--argjson available "$capability_available" \
	--argjson ready "$capability_ready" \
	--argjson canChange "$capability_can_change" \
	--arg reason "$reason" \
	'{
        vendor:$vendor,
        profile:$profile,
        profileLabel:$label,
        profiles:$profiles,
        profileLabels:$profiles,
        details:("Vendor profile: " + $label),
        tooltip:("Vendor profile: " + $label),
        errorCode:(if $reason == "" then null else $reason end)
    }')"
emit_status "$payload" "$capability_available" "$capability_ready" "$capability_can_change" not-required "$reason"
