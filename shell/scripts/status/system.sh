#!/usr/bin/env bash
set -u

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

profile="$(asusctl profile get 2>/dev/null | awk -F': ' '{print $2}')"
[ -n "$profile" ] || profile="Unknown"

fan1="$(cat /sys/class/hwmon/hwmon*/fan1_input 2>/dev/null | head -1)"
fan2="$(cat /sys/class/hwmon/hwmon*/fan2_input 2>/dev/null | head -1)"
fan1="${fan1:-}"
fan2="${fan2:-}"
if [ -n "${fan1:-}" ] && [ -n "${fan2:-}" ] && [ "$fan2" != "0" ]; then
	fan_rpm="$fan1 / $fan2"
elif [ -n "${fan1:-}" ]; then
	fan_rpm="$fan1"
else
	fan_rpm="N/A"
fi

cpu_temp="N/A"
for hwmon in /sys/class/hwmon/hwmon*/temp1_input; do
	[ -f "$hwmon" ] || continue
	name="$(cat "$(dirname "$hwmon")/name" 2>/dev/null)"
	if [[ "$name" =~ ^(k10temp|coretemp|zenpower)$ ]]; then
		temp="$(cat "$hwmon")"
		cpu_temp=$((temp / 1000))
		break
	fi
done

total_freq=0
freq_count=0
for freq in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
	[ -f "$freq" ] || continue
	total_freq=$((total_freq + $(cat "$freq")))
	((freq_count++))
done
[ "$freq_count" -gt 0 ] && cpu_clock="$(awk "BEGIN {printf \"%.2f\", $total_freq/$freq_count/1000000}")" || cpu_clock="N/A"

read -r _ user nice sys idle iowait irq softirq steal _ _ </proc/stat
total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
idle_total=$((idle + iowait))
cache_dir="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/quickshell"
cache="$cache_dir/system-cpu"
mkdir -p "$cache_dir"
if [ -f "$cache" ] && read -r prev_total prev_idle <"$cache" && [[ "$prev_total" =~ ^[0-9]+$ && "$prev_idle" =~ ^[0-9]+$ ]]; then
	diff_total=$((total - prev_total))
	diff_idle=$((idle_total - prev_idle))
	[ "$diff_total" -gt 0 ] && cpu_util=$(((diff_total - diff_idle) * 100 / diff_total)) || cpu_util=0
else
	cpu_util=0
fi
cache_tmp="${cache}.$$"
printf '%s %s\n' "$total" "$idle_total" >"$cache_tmp"
mv -f "$cache_tmp" "$cache"

power_uw="$(cat /sys/class/power_supply/BAT*/power_now 2>/dev/null | head -1)"
[ -n "${power_uw:-}" ] && power_w="$(awk "BEGIN {printf \"%.1f\", $power_uw/1000000}")" || power_w="N/A"

uptime_seconds="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
uptime_days=$((uptime_seconds / 86400))
uptime_hours=$(((uptime_seconds % 86400) / 3600))
uptime_minutes=$(((uptime_seconds % 3600) / 60))
if [ "$uptime_days" -gt 0 ]; then
	uptime_label="${uptime_days}d ${uptime_hours}h"
elif [ "$uptime_hours" -gt 0 ]; then
	uptime_label="${uptime_hours}h ${uptime_minutes}m"
else
	uptime_label="${uptime_minutes}m"
fi

read -r mem_total mem_avail < <(awk '/MemTotal:|MemAvailable:/ {print $2}' /proc/meminfo | xargs)
ram_used="$(awk "BEGIN {printf \"%.1f\", ($mem_total-$mem_avail)/1048576}")"
ram_total="$(awk "BEGIN {printf \"%.1f\", $mem_total/1048576}")"
ram_percent="$(awk "BEGIN {printf \"%d\", (($mem_total-$mem_avail)/$mem_total)*100}")"

read -r swap_total swap_free < <(awk '/SwapTotal:|SwapFree:/ {print $2}' /proc/meminfo | xargs)
swap_used="$(awk "BEGIN {printf \"%.1f\", ($swap_total-$swap_free)/1048576}")"
swap_total_gb="$(awk "BEGIN {printf \"%.1f\", $swap_total/1048576}")"
if [ "$swap_total" -gt 0 ]; then
	swap_percent="$(awk "BEGIN {printf \"%d\", (($swap_total-$swap_free)/$swap_total)*100}")"
else
	swap_percent=0
fi

refresh="$(hyprctl monitors -j 2>/dev/null | jq -r '((map(select(.name == "eDP-1"))[0].refreshRate // map(select(.focused))[0].refreshRate // .[0].refreshRate // 60) + 0.5) | floor' 2>/dev/null)"
[ -n "$refresh" ] || refresh="60"
if [ -n "$(lspci -s 01:00.0 2>/dev/null)" ]; then
	gpu_on=true
	if [ "$refresh" = "144" ]; then
		gpu_mode="gaming"
		gpu_label="Gaming: GPU + 144Hz"
	else
		gpu_mode="performance"
		gpu_label="Performance: GPU + 60Hz"
	fi
else
	gpu_on=false
	if [ "$refresh" = "144" ]; then
		gpu_mode="high-refresh"
		gpu_label="High refresh: iGPU + 144Hz"
	else
		gpu_mode="eco"
		gpu_label="Eco: iGPU + 60Hz"
	fi
fi

gpu_util=""
gpu_temp=""
vram_used=""
vram_total=""
gpu_stats="$(timeout 1 nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
if [ -n "$gpu_stats" ]; then
	IFS=',' read -r gpu_util gpu_temp vram_used vram_total <<<"$gpu_stats"
	gpu_util="${gpu_util//[[:space:]]/}"
	gpu_temp="${gpu_temp//[[:space:]]/}"
	vram_used="${vram_used//[[:space:]]/}"
	vram_total="${vram_total//[[:space:]]/}"
fi

payload="$(jq -nc \
	--arg profile "$profile" \
	--arg fanRpm "$fan_rpm" \
	--arg fan1Rpm "$fan1" \
	--arg fan2Rpm "$fan2" \
	--arg cpuTemp "$cpu_temp" \
	--arg cpuClock "$cpu_clock" \
	--arg powerW "$power_w" \
	--arg uptimeLabel "$uptime_label" \
	--arg ramUsed "$ram_used" \
	--arg ramTotal "$ram_total" \
	--arg swapUsed "$swap_used" \
	--arg swapTotal "$swap_total_gb" \
	--arg gpuMode "$gpu_mode" \
	--arg gpuLabel "$gpu_label" \
	--arg refresh "$refresh" \
	--arg gpuUtil "$gpu_util" \
	--arg gpuTemp "$gpu_temp" \
	--arg vramUsed "$vram_used" \
	--arg vramTotal "$vram_total" \
	--argjson cpuUtil "$cpu_util" \
	--argjson ramPercent "$ram_percent" \
	--argjson swapPercent "$swap_percent" \
	--argjson gpuOn "$gpu_on" \
	'{
	      profile:$profile,
	      fanRpm:$fanRpm,
	      fan1Rpm:$fan1Rpm,
	      fan2Rpm:$fan2Rpm,
      cpuTemp:$cpuTemp,
      cpuClock:$cpuClock,
      cpuUtil:$cpuUtil,
      powerW:$powerW,
      uptimeLabel:$uptimeLabel,
      ramUsed:$ramUsed,
      ramTotal:$ramTotal,
      ramPercent:$ramPercent,
      swapUsed:$swapUsed,
      swapTotal:$swapTotal,
      swapPercent:$swapPercent,
      gpuMode:$gpuMode,
      gpuLabel:$gpuLabel,
      gpuOn:$gpuOn,
      refresh:$refresh,
      gpuUtil:$gpuUtil,
      gpuTemp:$gpuTemp,
      vramUsed:$vramUsed,
      vramTotal:$vramTotal
    }')"
emit_status "$payload" true true false not-required ""
