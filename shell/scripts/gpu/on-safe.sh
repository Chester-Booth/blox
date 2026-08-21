#!/bin/bash

set -u

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shell/scripts/gpu/common.sh
source "$script_dir/common.sh"

if ! gpu_lock; then
	notify_gpu_busy
	exit 75
fi

if ! gpu_is_on; then
	gpu_notify -u normal "GPU" "Powering on"
	if ! sudo /usr/local/bin/gpu-pci-rescan; then
		gpu_notify -u critical "GPU" "PCI rescan failed"
		exit 1
	fi
	sleep 1.5
	for module in nvidia nvidia_drm nvidia_modeset nvidia_uvm; do
		if ! sudo modprobe "$module" 2>/dev/null; then
			gpu_notify -u critical "GPU" "Failed to load ${module}"
			exit 1
		fi
	done
	sleep 0.5
	if ! gpu_is_on; then
		gpu_notify -u critical "GPU" "GPU did not appear after PCI rescan"
		exit 1
	fi
	gpu_notify -u normal "GPU" "NVIDIA GPU ready"
fi
