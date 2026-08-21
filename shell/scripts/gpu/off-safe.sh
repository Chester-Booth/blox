#!/bin/bash

set -u

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shell/scripts/gpu/common.sh
source "$script_dir/common.sh" "$@"

if ! gpu_lock; then
	notify_gpu_busy
	exit 75
fi

if ! gpu_is_on; then
	exit 0
fi

if ! wait_for_gpu_nodes_idle; then
	busy_processes="$(gpu_busy_processes || true)"
	if [[ -n "$busy_processes" ]]; then
		message="NVIDIA GPU is in use by ${busy_processes}; close it and try Eco mode again."
		osd_message="Close ${busy_processes}, then retry"
	else
		message="NVIDIA GPU is still in use; close GPU applications and try Eco mode again."
		osd_message="Close GPU apps, then retry"
	fi
	printf '%s\n' "$message" >&2
	gpu_notify -u normal -e "GPU busy" "$osd_message" -i dialog-warning
	exit 1
fi

for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
	if module_loaded "$module" && ! unload_module "$module"; then
		printf 'Could not unload %s; the GPU remains on.\n' "$module" >&2
		gpu_notify -u normal -e "Eco mode failed" "${module} stayed loaded" -i dialog-warning
		exit 1
	fi
done

for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
	if module_loaded "$module"; then
		printf 'The %s module is still loaded; the GPU remains on.\n' "$module" >&2
		gpu_notify -u normal -e "Eco mode failed" "${module} stayed loaded" -i dialog-warning
		exit 1
	fi
done

if ! sudo /usr/local/bin/gpu-pci-remove; then
	printf 'Could not remove the NVIDIA GPU from the PCI bus.\n' >&2
	gpu_notify -u normal -e "Eco mode failed" "Could not power off GPU" -i dialog-error
	exit 1
fi

gpu_notify -u normal -e "NVIDIA GPU powered off"
