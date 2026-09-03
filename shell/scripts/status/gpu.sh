#!/usr/bin/env bash
set -u

# Discover graphics devices from DRM sysfs. GPU power switching remains an
# optional vendor operation and is never enabled by this read-only probe.
# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if ! command -v jq >/dev/null 2>&1; then
	emit_status '{"devices":[],"deviceCount":0,"discreteCount":0,"backend":"drm","mode":"unavailable","label":"GPU provider unavailable","gpuOn":false,"gpuUtil":"","gpuTemp":"","vramUsed":"","vramTotal":"","controlReason":"command-unavailable","tooltip":"GPU provider unavailable"}' false false false unknown command-unavailable
	exit 0
fi

shopt -s nullglob
vendor_files=(/sys/class/drm/card*/device/vendor)
shopt -u nullglob

device_lines=()
nvidia_count=0
for vendor_file in "${vendor_files[@]}"; do
	card_dir="${vendor_file%/vendor}"
	card_path="${card_dir%/device}"
	card="${card_path##*/}"
	vendor_id="$(<"$vendor_file")"
	case "$vendor_id" in
	0x1002) vendor="amd" ;;
	0x10de) vendor="nvidia"; ((nvidia_count++)) ;;
	0x8086) vendor="intel" ;;
	*) vendor="other" ;;
	esac
	driver_path="$(readlink -f "$card_dir/driver" 2>/dev/null || true)"
	driver="${driver_path##*/}"
	[[ -n "$driver" ]] || driver="unknown"
	boot_vga=false
	if [[ -r "$card_dir/boot_vga" ]] && [[ "$(<"$card_dir/boot_vga")" == "1" ]]; then
		boot_vga=true
	fi
	kind="discrete"
	[[ "$boot_vga" == true ]] && kind="integrated"
	device_lines+=("$(jq -nc \
		--arg id "$card" \
		--arg vendor "$vendor" \
		--arg driver "$driver" \
		--arg kind "$kind" \
		--argjson bootVga "$boot_vga" \
		'{id:$id,vendor:$vendor,driver:$driver,kind:$kind,bootVga:$bootVga}')")
done

if ((${#device_lines[@]} > 0)); then
	devices_json="$(printf '%s\n' "${device_lines[@]}" | jq -sc '.')"
else
	devices_json='[]'
fi

gpu_on=false
gpu_mode="eco"
gpu_label="Eco: integrated graphics"
gpu_util=""
gpu_temp=""
vram_used=""
vram_total=""
control_reason="no-supported-controller"
permission="not-required"

if ((nvidia_count > 0)); then
	gpu_label="Eco: NVIDIA graphics"
	permission="denied"
	control_reason="privileged-control"
	if nvidia_stats="$(timeout 1 nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)" && [[ -n "$nvidia_stats" ]]; then
		gpu_on=true
		gpu_mode="performance"
		gpu_label="Performance: NVIDIA graphics"
		IFS=',' read -r gpu_util gpu_temp vram_used vram_total <<<"$nvidia_stats"
		gpu_util="${gpu_util//[[:space:]]/}"
		gpu_temp="${gpu_temp//[[:space:]]/}"
		vram_used="${vram_used//[[:space:]]/}"
		vram_total="${vram_total//[[:space:]]/}"
	else
		control_reason="gpu-backend-unavailable"
	fi
elif ((${#device_lines[@]} > 0)); then
	first_gpu="${device_lines[0]}"
	gpu_vendor="$(jq -r '.vendor' <<<"$first_gpu")"
	gpu_label="$(jq -r '"Eco: " + (.vendor | ascii_upcase) + " graphics"' <<<"$first_gpu")"
	if [[ "$gpu_vendor" == "amd" ]]; then
		gpu_busy_file=""
		for candidate in /sys/class/drm/card*/device/gpu_busy_percent; do
			[[ -r "$candidate" ]] || continue
			gpu_busy_file="$candidate"
			break
		done
		[[ -r "$gpu_busy_file" ]] && gpu_util="$(<"$gpu_busy_file")"
	fi
else
	gpu_label="No graphics device"
	control_reason="no-gpu"
fi

device_count="$(jq 'length' <<<"$devices_json")"
discrete_count="$(jq '[.[] | select(.kind == "discrete")] | length' <<<"$devices_json")"
payload="$(jq -nc \
	--argjson devices "$devices_json" \
	--argjson deviceCount "$device_count" \
	--argjson discreteCount "$discrete_count" \
	--arg backend "drm" \
	--arg mode "$gpu_mode" \
	--arg label "$gpu_label" \
	--arg util "$gpu_util" \
	--arg temp "$gpu_temp" \
	--arg vramUsed "$vram_used" \
	--arg vramTotal "$vram_total" \
	--argjson gpuOn "$gpu_on" \
	--arg controlReason "$control_reason" \
	'{devices:$devices,deviceCount:$deviceCount,discreteCount:$discreteCount,backend:$backend,mode:$mode,label:$label,gpuOn:$gpuOn,gpuUtil:$util,gpuTemp:$temp,vramUsed:$vramUsed,vramTotal:$vramTotal,controlReason:$controlReason,tooltip:$label}')"

if [[ "$permission" == "denied" ]]; then
	emit_status "$payload" true true false denied "$control_reason"
else
	emit_status "$payload" true true false not-required "$control_reason"
fi
