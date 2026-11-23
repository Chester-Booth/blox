use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::json::{self, Json};

/// In-memory CPU tick sample for zero-disk-write CPU utilisation deltas.
#[derive(Default, Clone, Copy)]
pub struct CpuSample {
    pub total: u64,
    pub idle: u64,
    pub valid: bool,
}

fn read_trim(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read_trim(path)?.parse().ok()
}

fn read_fans() -> (String, String, String) {
    let mut fan1 = String::new();
    let mut fan2 = String::new();
    if let Ok(entries) = fs::read_dir("/sys/class/hwmon") {
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for dir in dirs {
            if fan1.is_empty() {
                if let Some(v) = read_trim(dir.join("fan1_input")) {
                    if !v.is_empty() {
                        fan1 = v;
                    }
                }
            }
            if fan2.is_empty() {
                if let Some(v) = read_trim(dir.join("fan2_input")) {
                    if !v.is_empty() {
                        fan2 = v;
                    }
                }
            }
            if !fan1.is_empty() && !fan2.is_empty() {
                break;
            }
        }
    }
    let fan_rpm = if !fan1.is_empty() && !fan2.is_empty() && fan2 != "0" {
        format!("{fan1} / {fan2}")
    } else if !fan1.is_empty() {
        fan1.clone()
    } else {
        "N/A".to_string()
    };
    (fan_rpm, fan1, fan2)
}

fn read_cpu_temp() -> String {
    if let Ok(entries) = fs::read_dir("/sys/class/hwmon") {
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for dir in dirs {
            let Some(name) = read_trim(dir.join("name")) else { continue };
            if matches!(name.as_str(), "k10temp" | "coretemp" | "zenpower") {
                if let Some(raw) = read_u64(dir.join("temp1_input")) {
                    return (raw / 1000).to_string();
                }
            }
        }
    }
    "N/A".to_string()
}

fn read_cpu_clock() -> String {
    let mut total: u64 = 0;
    let mut count: u64 = 0;
    if let Ok(entries) = fs::read_dir("/sys/devices/system/cpu") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let s = name.to_string_lossy();
            if !s.starts_with("cpu") || !s[3..].chars().all(|c| c.is_ascii_digit()) || s.len() <= 3 {
                continue;
            }
            if let Some(freq) = read_u64(entry.path().join("cpufreq/scaling_cur_freq")) {
                total += freq;
                count += 1;
            }
        }
    }
    if count > 0 {
        format!("{:.2}", (total as f64) / (count as f64) / 1_000_000.0)
    } else {
        "N/A".to_string()
    }
}

fn read_proc_stat() -> Option<(u64, u64)> {
    let content = fs::read_to_string("/proc/stat").ok()?;
    let line = content.lines().next()?;
    let mut nums = line.split_whitespace().skip(1).filter_map(|t| t.parse::<u64>().ok());
    let user = nums.next()?;
    let nice = nums.next()?;
    let sys = nums.next()?;
    let idle = nums.next()?;
    let iowait = nums.next().unwrap_or(0);
    let irq = nums.next().unwrap_or(0);
    let softirq = nums.next().unwrap_or(0);
    let steal = nums.next().unwrap_or(0);
    let total = user + nice + sys + idle + iowait + irq + softirq + steal;
    Some((total, idle + iowait))
}

fn compute_cpu_util(prev: &mut CpuSample) -> i64 {
    let Some((total, idle)) = read_proc_stat() else {
        return 0;
    };
    let util = if prev.valid && total > prev.total {
        let dt = total - prev.total;
        let di = idle.saturating_sub(prev.idle);
        ((dt.saturating_sub(di)) * 100 / dt) as i64
    } else {
        0
    };
    prev.total = total;
    prev.idle = idle;
    prev.valid = true;
    util
}

fn read_power_w() -> String {
    if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        dirs.sort();
        for dir in dirs {
            if dir.file_name().and_then(|n| n.to_str()).map(|s| s.starts_with("BAT")).unwrap_or(false) {
                if let Some(uw) = read_u64(dir.join("power_now")) {
                    return format!("{:.1}", uw as f64 / 1_000_000.0);
                }
            }
        }
    }
    "N/A".to_string()
}

fn read_uptime() -> String {
    let secs: u64 = read_trim("/proc/uptime")
        .and_then(|s| s.split('.').next().and_then(|n| n.parse().ok()))
        .unwrap_or(0);
    let days = secs / 86400;
    let hours = (secs % 86400) / 3600;
    let mins = (secs % 3600) / 60;
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {mins}m")
    } else {
        format!("{mins}m")
    }
}

fn read_memory() -> (String, String, i64, String, String, i64) {
    let mut mem_total: u64 = 0;
    let mut mem_avail: u64 = 0;
    let mut swap_total: u64 = 0;
    let mut swap_free: u64 = 0;
    if let Ok(content) = fs::read_to_string("/proc/meminfo") {
        for line in content.lines() {
            let mut parts = line.split_whitespace();
            let Some(key) = parts.next() else { continue };
            let Some(val) = parts.next().and_then(|v| v.parse::<u64>().ok()) else { continue };
            match key {
                "MemTotal:" => mem_total = val,
                "MemAvailable:" => mem_avail = val,
                "SwapTotal:" => swap_total = val,
                "SwapFree:" => swap_free = val,
                _ => {}
            }
        }
    }
    let ram_used_kb = mem_total.saturating_sub(mem_avail);
    let ram_used = format!("{:.1}", ram_used_kb as f64 / 1_048_576.0);
    let ram_total = format!("{:.1}", mem_total as f64 / 1_048_576.0);
    let ram_pct = if mem_total > 0 { ((ram_used_kb as f64 / mem_total as f64) * 100.0) as i64 } else { 0 };
    let swap_used_kb = swap_total.saturating_sub(swap_free);
    let swap_used = format!("{:.1}", swap_used_kb as f64 / 1_048_576.0);
    let swap_total_gb = format!("{:.1}", swap_total as f64 / 1_048_576.0);
    let swap_pct = if swap_total > 0 { ((swap_used_kb as f64 / swap_total as f64) * 100.0) as i64 } else { 0 };
    (ram_used, ram_total, ram_pct, swap_used, swap_total_gb, swap_pct)
}

fn nvidia_is_active() -> bool {
    let Ok(entries) = fs::read_dir("/sys/bus/pci/devices") else { return false };
    for entry in entries.flatten() {
        let dir = entry.path();
        if read_trim(dir.join("vendor")).as_deref() != Some("0x10de") {
            continue;
        }
        if !read_trim(dir.join("class")).map(|c| c.starts_with("0x03")).unwrap_or(false) {
            continue;
        }
        if read_trim(dir.join("power/runtime_status")).as_deref() == Some("active") {
            return true;
        }
    }
    false
}

fn read_nvidia_stats() -> (String, String, String, String) {
    if !nvidia_is_active() {
        return (String::new(), String::new(), String::new(), String::new());
    }
    let output = Command::new("nvidia-smi")
        .args([
            "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    let Ok(out) = output else {
        return (String::new(), String::new(), String::new(), String::new());
    };
    if !out.status.success() {
        return (String::new(), String::new(), String::new(), String::new());
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let Some(line) = text.lines().next() else {
        return (String::new(), String::new(), String::new(), String::new());
    };
    let parts: Vec<String> = line.split(',').map(|p| p.trim().to_string()).collect();
    if parts.len() >= 4 {
        (parts[0].clone(), parts[1].clone(), parts[2].clone(), parts[3].clone())
    } else {
        (String::new(), String::new(), String::new(), String::new())
    }
}

/// Collect system metrics using an in-memory CPU sample (zero subprocess forks when dGPU asleep).
pub fn collect(sample: &mut CpuSample) -> Json {
    let (fan_rpm, fan1, fan2) = read_fans();
    let cpu_temp = read_cpu_temp();
    let cpu_clock = read_cpu_clock();
    let cpu_util = compute_cpu_util(sample);
    let power_w = read_power_w();
    let uptime_label = read_uptime();
    let (ram_used, ram_total, ram_pct, swap_used, swap_total, swap_pct) = read_memory();
    let (gpu_util, gpu_temp, vram_used, vram_total) = read_nvidia_stats();

    Json::obj([
        ("profile", Json::String("Unknown".to_string())),
        ("fanRpm", Json::String(fan_rpm)),
        ("fan1Rpm", Json::String(fan1)),
        ("fan2Rpm", Json::String(fan2)),
        ("cpuTemp", Json::String(cpu_temp)),
        ("cpuClock", Json::String(cpu_clock)),
        ("cpuUtil", Json::Int(cpu_util)),
        ("powerW", Json::String(power_w)),
        ("uptimeLabel", Json::String(uptime_label)),
        ("ramUsed", Json::String(ram_used)),
        ("ramTotal", Json::String(ram_total)),
        ("ramPercent", Json::Int(ram_pct)),
        ("swapUsed", Json::String(swap_used)),
        ("swapTotal", Json::String(swap_total)),
        ("swapPercent", Json::Int(swap_pct)),
        ("gpuUtil", Json::String(gpu_util)),
        ("gpuTemp", Json::String(gpu_temp)),
        ("vramUsed", Json::String(vram_used)),
        ("vramTotal", Json::String(vram_total)),
        ("capability", json::capability(true, true, false, "not-required", None)),
    ])
}

/// One-shot collector persisting CPU ticks in $XDG_RUNTIME_DIR/quickshell/system-cpu.
pub fn collect_oneshot() -> Json {
    let cache_dir = env::var_os("XDG_RUNTIME_DIR")
        .or_else(|| env::var_os("XDG_CACHE_HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("HOME").unwrap_or_default()).join(".cache"))
        .join("quickshell");
    let cache_file = cache_dir.join("system-cpu");
    let mut sample = CpuSample::default();
    if let Some(raw) = read_trim(&cache_file) {
        let mut parts = raw.split_whitespace();
        if let (Some(t), Some(i)) = (
            parts.next().and_then(|v| v.parse::<u64>().ok()),
            parts.next().and_then(|v| v.parse::<u64>().ok()),
        ) {
            sample = CpuSample { total: t, idle: i, valid: true };
        }
    }
    let payload = collect(&mut sample);
    if sample.valid {
        let _ = fs::create_dir_all(&cache_dir);
        let tmp = cache_dir.join(format!("system-cpu.{}", std::process::id()));
        if fs::write(&tmp, format!("{} {}\n", sample.total, sample.idle)).is_ok() {
            let _ = fs::rename(tmp, cache_file);
        }
    }
    payload
}
