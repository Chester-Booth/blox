#!/usr/bin/env bash
set -u

json_mode=false
ignore_inhibitors=false
action=""
extra_arg=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--json)
		json_mode=true
		;;
	--ignore-inhibitors|-i)
		ignore_inhibitors=true
		;;
	*)
		if [[ -z "$action" ]]; then
			action="$1"
		elif [[ -z "$extra_arg" ]]; then
			extra_arg="$1"
		fi
		;;
	esac
	shift
done

notify() {
	command -v notify-send >/dev/null 2>&1 || return 0
	notify-send -u critical -i dialog-warning "Power action blocked" "$1"
}

emit_json_result() {
	local ok="$1"
	local code="$2"
	local message="$3"
	local data_json="${4:-null}"

	if command -v jq >/dev/null 2>&1; then
		jq -cn \
			--argjson ok "$ok" \
			--arg code "$code" \
			--arg message "$message" \
			--argjson data "$data_json" \
			'{version:1,ok:$ok,code:$code,message:$message,data:$data}'
	else
		printf '{"version":1,"ok":%s,"code":"%s","message":"%s","data":null}\n' \
			"$ok" "$code" "${message//\"/\'}"
	fi
}

fail_action() {
	local code="$1"
	local message="$2"
	local data_json="${3:-null}"
	local exit_code="${4:-1}"

	if [[ "$json_mode" == true ]]; then
		emit_json_result false "$code" "$message" "$data_json"
	else
		notify "$message"
		printf '%s\n' "$message" >&2
	fi
	exit "$exit_code"
}

succeed_action() {
	local action_name="$1"
	if [[ "$json_mode" == true ]]; then
		local data_json="null"
		if command -v jq >/dev/null 2>&1; then
			data_json="$(jq -cn --arg action "$action_name" '{action:$action}')"
		fi
		emit_json_result true "ok" "" "$data_json"
	fi
	exit 0
}

children_of() {
	local parent="$1"
	local child

	pgrep -P "$parent" 2>/dev/null | while read -r child; do
		printf '%s\n' "$child"
		children_of "$child"
	done
}

process_is_micro() {
	local pid="$1"
	local comm=""
	local cmdline=""

	[[ -r "/proc/$pid/comm" ]] && comm="$(<"/proc/$pid/comm")"
	[[ "$comm" == "micro" ]] && return 0

	if [[ -r "/proc/$pid/cmdline" ]]; then
		cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
		[[ "$cmdline" =~ (^|[[:space:]/])micro([[:space:]]|$) ]] && return 0
	fi

	return 1
}

special_micro_sessions() {
	local client_pid workspace title pid

	command -v hyprctl >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0

	hyprctl clients -j 2>/dev/null |
		jq -r '
            .[]
            | select((.workspace.name | tostring | startswith("special")))
            | select(((.class // "") | ascii_downcase) == "kitty" or ((.initialClass // "") | ascii_downcase) == "kitty")
            | [.pid, .workspace.name, (.title // "kitty")] | @tsv
        ' 2>/dev/null |
		while IFS=$'\t' read -r client_pid workspace title; do
			[[ -n "$client_pid" ]] || continue

			if process_is_micro "$client_pid"; then
				printf '%s\t%s\n' "$workspace" "$title"
				continue
			fi

			while read -r pid; do
				if process_is_micro "$pid"; then
					printf '%s\t%s\n' "$workspace" "$title"
					break
				fi
			done < <(children_of "$client_pid")
		done
}

micro_items_json() {
	local sessions
	sessions="$(special_micro_sessions | sort -u)"
	if [[ -z "$sessions" ]] || ! command -v jq >/dev/null 2>&1; then
		printf '[]\n'
		return 0
	fi

	printf '%s\n' "$sessions" | jq -Rsc '
		split("\n")
		| map(select(length > 0) | split("\t"))
		| map({
			who: (.[0] // "special"),
			why: ("micro · " + (.[1] // "kitty")),
			meta: "kitty",
			workspace: (.[0] // "")
		})
	'
}

# Lists active systemd-logind block inhibitors matching a given scope ("sleep" or "shutdown").
# Only mode == "block" locks match; delay inhibitors and idle-only locks (e.g. Blox Awake) are excluded.
# Shutdown-class actions also treat sleep block inhibitors as blockers because powering off or rebooting
# interrupts active work more severely than sleeping.
block_inhibitors_json() {
	local scope="$1"
	local raw=""

	if ! command -v busctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
		printf '[]\n'
		return 0
	fi

	raw="$(busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors 2>/dev/null || true)"
	if [[ -z "$raw" ]]; then
		printf '[]\n'
		return 0
	fi

	printf '%s\n' "$raw" | jq -c --arg scope "$scope" '
		(.data[0] // [])
		| map(
			select((.[3] // "") == "block")
			| ((.[0] // "") | split(":")) as $scopes
			| select(
				if $scope == "shutdown" then
					(($scopes | index("shutdown")) != null) or (($scopes | index("sleep")) != null)
				else
					($scopes | index($scope)) != null
				end
			)
			| {
				who: (.[1] // "Unknown app"),
				why: (.[2] // "Blocking power action"),
				pid: (.[5] // 0),
				meta: (if (.[5] // 0) > 0 then ("PID " + ((.[5] // 0) | tostring)) else "" end)
			}
		)
	' 2>/dev/null || printf '[]\n'
}

focus_special_workspace() {
	local target="${1#special:}"
	if [[ "$target" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
		hyprctl dispatch "hl.dsp.workspace.toggle_special(\"$target\")" >/dev/null 2>&1 || true
		return 0
	fi
	return 1
}

guard_micro_before_power_action() {
	local items_json count first_workspace message data_json

	items_json="$(micro_items_json)"
	count="$(printf '%s\n' "$items_json" | jq 'length' 2>/dev/null || printf '0')"
	[[ "$count" -gt 0 ]] || return 0

	first_workspace="$(printf '%s\n' "$items_json" | jq -r '.[0].workspace // ""' 2>/dev/null || true)"
	if [[ "$count" -eq 1 ]]; then
		message="micro is open in ${first_workspace}. Save or close it before ${action}."
	else
		message="${count} micro sessions are open in special workspaces. Save or close them before ${action}."
	fi

	if [[ "$json_mode" == true ]]; then
		data_json="$(jq -cn \
			--arg action "$action" \
			--arg workspace "$first_workspace" \
			--argjson items "$items_json" \
			'{action:$action,workspace:$workspace,items:$items}')"
		fail_action "micro-open" "$message" "$data_json" 1
	fi

	notify "$message"
	printf '%s\n' "$message" >&2
	focus_special_workspace "$first_workspace" || true
	exit 1
}

guard_inhibitors_before_power_action() {
	local scope="$1"
	local items_json count first_who first_why message data_json

	[[ "$ignore_inhibitors" == true ]] && return 0

	items_json="$(block_inhibitors_json "$scope")"
	count="$(printf '%s\n' "$items_json" | jq 'length' 2>/dev/null || printf '0')"
	[[ "$count" -gt 0 ]] || return 0

	first_who="$(printf '%s\n' "$items_json" | jq -r '.[0].who // "An app"' 2>/dev/null || printf 'An app')"
	first_why="$(printf '%s\n' "$items_json" | jq -r '.[0].why // ""' 2>/dev/null || true)"
	if [[ "$count" -eq 1 ]]; then
		if [[ -n "$first_why" ]]; then
			message="${action^} blocked by ${first_who}: ${first_why}."
		else
			message="${action^} blocked by ${first_who}."
		fi
	else
		message="${action^} blocked by ${count} active apps."
	fi

	data_json="$(jq -cn \
		--arg action "$action" \
		--arg scope "$scope" \
		--argjson items "$items_json" \
		'{action:$action,scope:$scope,items:$items}')"
	fail_action "inhibited" "$message" "$data_json" 1
}

save_kitty_tabs_before_power_action() {
	command -v ktr >/dev/null 2>&1 || return 0
	ktr save --all </dev/null >/dev/null 2>&1 || true
}

# Launches hyprlock detached with closed stdio so callers reading stdout/stderr get EOF immediately.
lock_session() {
	local lock_pid data_json message

	pgrep -x hyprlock >/dev/null 2>&1 && return 0
	hyprlock --immediate-render </dev/null >/dev/null 2>&1 &
	lock_pid=$!
	sleep 0.4

	if kill -0 "$lock_pid" 2>/dev/null; then
		return 0
	fi

	wait "$lock_pid" 2>/dev/null || true
	message="Hyprlock failed to start, so ${action} was cancelled."
	if command -v jq >/dev/null 2>&1; then
		data_json="$(jq -cn \
			--arg action "$action" \
			--arg reason "$message" \
			'{action:$action,items:[{who:"hyprlock",why:$reason,meta:""}]}')"
	else
		data_json="null"
	fi
	fail_action "lock-failed" "$message" "$data_json" 1
}

run_systemctl_power() {
	local verb="$1"
	local scope="$2"
	local -a cmd=(systemctl "$verb")
	local output status first_line code data_json

	if [[ "$ignore_inhibitors" == true ]]; then
		cmd+=(-i)
	fi

	output="$("${cmd[@]}" 2>&1 </dev/null)"
	status=$?
	if [[ "$status" -eq 0 ]]; then
		succeed_action "$action"
	fi

	first_line="$(printf '%s\n' "$output" | awk 'NF { print; exit }')"
	[[ -n "$first_line" ]] || first_line="systemctl ${verb} failed (exit ${status})."

	if printf '%s\n' "$output" | grep -qiE 'Operation inhibited by|is logged in on'; then
		code="inhibited"
	else
		code="failed"
	fi

	if command -v jq >/dev/null 2>&1; then
		data_json="$(jq -cn \
			--arg action "$action" \
			--arg scope "$scope" \
			--arg detail "$first_line" \
			--argjson exitCode "$status" \
			'{action:$action,scope:$scope,exitCode:$exitCode,items:[{who:"systemd-logind",why:$detail,meta:""}]}')"
	else
		data_json="null"
	fi
	fail_action "$code" "$first_line" "$data_json" "$status"
}

case "$action" in
inhibitors)
	if command -v jq >/dev/null 2>&1; then
		jq -cn \
			--argjson sleep "$(block_inhibitors_json sleep)" \
			--argjson shutdown "$(block_inhibitors_json shutdown)" \
			--argjson micro "$(micro_items_json)" \
			'{sleep:$sleep,shutdown:$shutdown,micro:$micro}'
	else
		printf '{"sleep":[],"shutdown":[],"micro":[]}\n'
	fi
	exit 0
	;;
precheck)
	target_action="${extra_arg:-shutdown}"
	action="$target_action"
	guard_micro_before_power_action
	case "$target_action" in
	sleep|hibernate)
		guard_inhibitors_before_power_action sleep
		;;
	*)
		guard_inhibitors_before_power_action shutdown
		;;
	esac
	exit 0
	;;
focus-special)
	if [[ -z "$extra_arg" ]]; then
		fail_action "invalid-data" "No special workspace was specified." "null" 2
	fi
	if focus_special_workspace "$extra_arg"; then
		succeed_action "focus-special"
	fi
	fail_action "invalid-data" "Invalid special workspace name: ${extra_arg}." "null" 2
	;;
lock)
	lock_session
	succeed_action "lock"
	;;
sleep)
	guard_micro_before_power_action
	guard_inhibitors_before_power_action sleep
	save_kitty_tabs_before_power_action
	lock_session
	run_systemctl_power suspend-then-hibernate sleep
	;;
shutdown)
	guard_micro_before_power_action
	guard_inhibitors_before_power_action shutdown
	save_kitty_tabs_before_power_action
	run_systemctl_power poweroff shutdown
	;;
reboot)
	guard_micro_before_power_action
	guard_inhibitors_before_power_action shutdown
	save_kitty_tabs_before_power_action
	run_systemctl_power reboot shutdown
	;;
hibernate)
	guard_micro_before_power_action
	guard_inhibitors_before_power_action sleep
	save_kitty_tabs_before_power_action
	lock_session
	run_systemctl_power hibernate sleep
	;;
logout)
	save_kitty_tabs_before_power_action
	exec hyprctl dispatch 'hl.dsp.exit()'
	;;
*)
	fail_action "invalid-data" "Unknown power action: ${action:-empty}" "null" 2
	;;
esac
