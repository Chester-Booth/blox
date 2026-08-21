#!/usr/bin/env bash
set -u

action="${1:-}"

notify() {
	notify-send -u critical -i dialog-warning "Power action blocked" "$1"
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

guard_micro_before_power_action() {
	local sessions first_workspace count message special_name

	sessions="$(special_micro_sessions | sort -u)"
	[[ -n "$sessions" ]] || return 0

	count="$(printf '%s\n' "$sessions" | sed '/^$/d' | wc -l)"
	first_workspace="$(printf '%s\n' "$sessions" | awk -F '\t' 'NR == 1 { print $1 }')"

	if [[ "$count" -eq 1 ]]; then
		message="micro is open in ${first_workspace}. Save or close it before ${action}."
	else
		message="${count} micro sessions are open in special workspaces. Save or close them before ${action}."
	fi

	notify "$message"
	special_name="${first_workspace#special:}"
	if [[ "$special_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
		hyprctl dispatch "hl.dsp.workspace.toggle_special(\"$special_name\")" >/dev/null 2>&1 || true
	fi
	return 1
}

save_kitty_tabs_before_power_action() {
	command -v ktr >/dev/null 2>&1 || return 0
	ktr save --all >/dev/null 2>&1 || true
}

lock_before_sleep() {
	local lock_pid

	pgrep -x hyprlock >/dev/null 2>&1 && return 0
	hyprlock --immediate-render >/dev/null 2>&1 &
	lock_pid=$!
	sleep 1

	if kill -0 "$lock_pid" 2>/dev/null; then
		return 0
	fi

	wait "$lock_pid" 2>/dev/null || true
	notify "Hyprlock failed to start, so ${action} was cancelled."
	return 1
}

case "$action" in
lock)
	exec hyprlock
	;;
sleep)
	guard_micro_before_power_action || exit 1
	save_kitty_tabs_before_power_action
	lock_before_sleep || exit 1
	exec systemctl suspend-then-hibernate
	;;
shutdown)
	guard_micro_before_power_action || exit 1
	save_kitty_tabs_before_power_action
	exec systemctl poweroff
	;;
reboot)
	guard_micro_before_power_action || exit 1
	save_kitty_tabs_before_power_action
	exec systemctl reboot
	;;
hibernate)
	guard_micro_before_power_action || exit 1
	save_kitty_tabs_before_power_action
	lock_before_sleep || exit 1
	exec systemctl hibernate
	;;
*)
	notify "Unknown power action: ${action:-empty}"
	exit 2
	;;
esac
