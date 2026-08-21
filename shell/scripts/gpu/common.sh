#!/bin/bash

gpu_notifications_enabled=1
gpu_notice="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/blox/scripts/osd/notice.sh"
gpu_idle_attempts=40
gpu_idle_delay=0.25
gpu_unload_attempts=8
gpu_unload_delay=0.35

for gpu_arg in "$@"; do
	case "$gpu_arg" in
	--quiet | --no-notify)
		gpu_notifications_enabled=0
		;;
	--idle-attempts=*)
		gpu_idle_attempts="${gpu_arg#*=}"
		;;
	--idle-delay=*)
		gpu_idle_delay="${gpu_arg#*=}"
		;;
	esac
done

gpu_lock() {
	local runtime_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quickshell}"
	local lock_file="$runtime_dir/gpu-power.lock"

	mkdir -p "$runtime_dir"
	exec 9>"$lock_file"
	flock -n 9
}

gpu_is_on() {
	[[ -n "$(lspci -s 01:00.0 2>/dev/null)" ]]
}

gpu_nodes_in_use() {
	local nodes=()

	shopt -s nullglob
	nodes=(/dev/nvidia*)
	shopt -u nullglob

	((${#nodes[@]} > 0)) || return 1
	sudo fuser "${nodes[@]}" &>/dev/null
}

gpu_busy_processes() {
	local nodes=()
	local pids=()
	local pid_list

	shopt -s nullglob
	nodes=(/dev/nvidia*)
	shopt -u nullglob

	((${#nodes[@]} > 0)) || return 1
	read -r -a pids <<<"$(sudo fuser "${nodes[@]}" 2>/dev/null || true)"
	((${#pids[@]} > 0)) || return 1

	printf -v pid_list '%s,' "${pids[@]}"
	ps -o comm= -p "${pid_list%,}" 2>/dev/null |
		awk 'NF && !seen[$0]++ { names[++count] = $0 } END { for (i = 1; i <= count; i++) printf "%s%s", names[i], (i < count ? ", " : ORS) }'
}

wait_for_gpu_nodes_idle() {
	local attempts="${1:-$gpu_idle_attempts}"
	local delay="${2:-$gpu_idle_delay}"
	local i

	for ((i = 0; i < attempts; i++)); do
		if ! gpu_nodes_in_use; then
			return 0
		fi
		sleep "$delay"
	done

	return 1
}

module_loaded() {
	lsmod | awk '{print $1}' | grep -qx "$1"
}

unload_module() {
	local module="$1"
	local i

	for ((i = 0; i < gpu_unload_attempts; i++)); do
		if ! module_loaded "$module"; then
			return 0
		fi

		sudo rmmod "$module" 2>/dev/null || true
		sleep "$gpu_unload_delay"
	done

	! module_loaded "$module"
}

gpu_notify() {
	if ((gpu_notifications_enabled)); then
		local title="GPU Manager"
		local message=""
		local icon="󰢮"
		local level="normal"
		local args=()

		while (($#)); do
			case "$1" in
			-u)
				shift
				case "${1:-normal}" in
				critical) level="critical" ;;
				normal) level="warning" ;;
				*) level="normal" ;;
				esac
				;;
			-i)
				shift
				;;
			-e)
				;;
			-*)
				;;
			*)
				args+=("$1")
				;;
			esac
			shift
		done

		((${#args[@]} >= 1)) && title="${args[0]}"
		((${#args[@]} >= 2)) && message="${args[1]}"
		"$gpu_notice" "$title" "$message" "$icon" "$level" 4500
	fi
}

notify_gpu_busy() {
	gpu_notify -u normal -e "GPU Manager" "GPU power operation already in progress." -i dialog-information
}
