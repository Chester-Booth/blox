#!/usr/bin/env bash

# Add the shared typed capability envelope to a producer payload. The payload
# remains responsible for its domain fields and presentation text.
emit_status() {
	local payload="$1"
	local available="${2:-true}"
	local ready="${3:-true}"
	local can_change="${4:-false}"
	local permission="${5:-not-required}"
	local reason="${6:-}"

	jq -cn \
		--argjson payload "$payload" \
		--argjson available "$available" \
		--argjson ready "$ready" \
		--argjson canChange "$can_change" \
		--arg permission "$permission" \
		--arg reason "$reason" \
		'$payload + {capability: {available: $available, ready: $ready, canChange: $canChange, permission: $permission, reason: (if $reason == "" then null else $reason end)}}'
}
