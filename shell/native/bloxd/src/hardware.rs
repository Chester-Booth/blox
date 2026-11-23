use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::hypr;
use crate::json::{self, Json};

#[repr(C)]
struct Tm {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
    tm_gmtoff: isize,
    tm_zone: *const i8,
}

unsafe extern "C" {
    fn time(t: *mut i64) -> i64;
    fn localtime_r(timep: *const i64, result: *mut Tm) -> *mut Tm;
}

fn local_minutes_since_midnight() -> i32 {
    let mut now: i64 = 0;
    unsafe {
        time(&mut now);
        let mut out = std::mem::zeroed::<Tm>();
        if !localtime_r(&now, &mut out).is_null() {
            return out.tm_hour * 60 + out.tm_min;
        }
    }
    0
}

pub fn command_exists(name: &str) -> bool {
    let Some(paths) = env::var_os("PATH") else { return false };
    for dir in env::split_paths(&paths) {
        let candidate = dir.join(name);
        if let Ok(meta) = fs::metadata(&candidate) {
            if meta.is_file() && (meta.permissions().mode() & 0o111 != 0) {
                return true;
            }
        }
    }
    false
}

/// Scan /proc/*/comm natively without spawning pgrep.
pub fn process_running(comm: &str) -> bool {
    let Ok(entries) = fs::read_dir("/proc") else { return false };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if let Ok(raw) = fs::read_to_string(entry.path().join("comm")) {
            if raw.trim() == comm {
                return true;
            }
        }
    }
    false
}

fn cache_dir() -> PathBuf {
    env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("HOME").unwrap_or_default()).join(".cache"))
        .join("quickshell")
}

fn state_dir() -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("HOME").unwrap_or_default()).join(".local/state"))
        .join("quickshell")
}

fn runtime_dir() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("HOME").unwrap_or_default()).join(".cache"))
}

fn blue_light_mode() -> String {
    let raw = fs::read_to_string(cache_dir().join("blue-light-mode"))
        .ok()
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    match raw.as_str() {
        "on" | "off" | "auto" => raw,
        _ => "auto".to_string(),
    }
}

fn evaluate_hyprsunset_schedule(mode: &str) -> bool {
    match mode {
        "on" => return true,
        "off" | "disable" | "disabled" => return false,
        _ => {}
    }
    let config_path = cache_dir().join("hyprsunset/hypr/hyprsunset.conf");
    let Ok(text) = fs::read_to_string(config_path) else {
        return false;
    };
    let now = local_minutes_since_midnight();
    let mut in_profile = false;
    let mut profile_time = String::new();
    let mut profile_active = false;
    let mut selected_active = false;
    let mut selected_seen = false;
    let mut last_active = false;

    let finish = |in_prof: bool,
                  ptime: &str,
                  pactive: bool,
                  sel_act: &mut bool,
                  sel_seen: &mut bool,
                  last_act: &mut bool| {
        if !in_prof || ptime.is_empty() {
            return;
        }
        let mut parts = ptime.split(':');
        let h: i32 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0);
        let m: i32 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0);
        if h * 60 + m <= now {
            *sel_act = pactive;
            *sel_seen = true;
        }
        *last_act = pactive;
    };

    for line in text.lines() {
        let s = line.trim();
        if s.starts_with("profile") && s.ends_with('{') {
            in_profile = true;
            profile_time.clear();
            profile_active = false;
        } else if in_profile && s.starts_with("time") && s.contains('=') {
            if let Some((_, val)) = s.split_once('=') {
                profile_time = val.chars().filter(|c| !c.is_whitespace()).collect();
            }
        } else if in_profile && s.starts_with("temperature") && s.contains('=') {
            profile_active = true;
        } else if in_profile && s.starts_with("identity") && s.contains("true") {
            profile_active = false;
        } else if in_profile && s == "}" {
            finish(in_profile, &profile_time, profile_active, &mut selected_active, &mut selected_seen, &mut last_active);
            in_profile = false;
        }
    }
    finish(in_profile, &profile_time, profile_active, &mut selected_active, &mut selected_seen, &mut last_active);
    if selected_seen { selected_active } else { last_active }
}

pub fn night_light_status() -> Json {
    let mode = blue_light_mode();
    let available = command_exists("hyprsunset");
    let active = if process_running("hyprsunset") {
        evaluate_hyprsunset_schedule(&mode)
    } else {
        false
    };
    Json::obj([
        ("mode", Json::String(mode)),
        ("active", Json::Bool(active)),
        ("available", Json::Bool(available)),
    ])
}

fn list_backlights() -> Vec<String> {
    let mut names = Vec::new();
    if let Ok(entries) = fs::read_dir("/sys/class/backlight") {
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                if let Some(name) = entry.file_name().to_str() {
                    names.push(name.to_string());
                }
            }
        }
    }
    names.sort();
    names
}

fn read_backlight_percent(device: &str) -> Option<i64> {
    let dir = Path::new("/sys/class/backlight").join(device);
    let max: u64 = fs::read_to_string(dir.join("max_brightness")).ok()?.trim().parse().ok()?;
    if max == 0 {
        return None;
    }
    let cur: u64 = fs::read_to_string(dir.join("brightness"))
        .or_else(|_| fs::read_to_string(dir.join("actual_brightness")))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    let pct = ((cur as f64 / max as f64) * 100.0).round() as i64;
    Some(pct.clamp(0, 100))
}

/// Direct /sys/class/backlight reader. Never probes I2C buses with ddcutil unless requested.
pub fn brightness_status(requested_device: &str, probe_ddc: bool) -> Json {
    let backlights = list_backlights();
    let device = if !requested_device.is_empty() {
        requested_device.to_string()
    } else {
        backlights.first().cloned().unwrap_or_default()
    };
    let backlights_json = Json::Array(backlights.iter().cloned().map(Json::String).collect());
    let has_ddcutil = command_exists("ddcutil");
    let (ddc_available, ddc_count, ddc_reason) = if !has_ddcutil {
        (false, 0_i64, "command-unavailable".to_string())
    } else if !probe_ddc {
        (false, 0_i64, "no-ddc-display".to_string())
    } else {
        let count = Command::new("ddcutil")
            .args(["detect", "--brief"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .filter(|l| l.starts_with("Display "))
                    .count() as i64
            })
            .unwrap_or(0);
        if count > 0 {
            (true, count, String::new())
        } else {
            (false, 0, "no-ddc-display".to_string())
        }
    };

    if !command_exists("brightnessctl") && backlights.is_empty() {
        return Json::obj([
            ("icon", Json::String("󰃠".to_string())),
            ("percent", Json::Int(0)),
            ("blueLightMode", Json::String("auto".to_string())),
            ("blueLightActive", Json::Bool(false)),
            ("device", Json::String(String::new())),
            ("backlightCount", Json::Int(0)),
            ("backlights", backlights_json),
            ("ddcAvailable", Json::Bool(false)),
            ("ddcDisplayCount", Json::Int(ddc_count)),
            ("ddcReason", Json::String(ddc_reason)),
            ("details", Json::String("Brightness status unavailable".to_string())),
            ("tooltip", Json::String("Brightness status unavailable".to_string())),
            ("capability", json::capability(false, false, false, "unknown", Some("command-unavailable"))),
        ]);
    }

    let Some(percent) = (!device.is_empty()).then(|| read_backlight_percent(&device)).flatten() else {
        return Json::obj([
            ("icon", Json::String("󰃠".to_string())),
            ("percent", Json::Int(0)),
            ("blueLightMode", Json::String("auto".to_string())),
            ("blueLightActive", Json::Bool(false)),
            ("device", Json::String(device)),
            ("backlightCount", Json::Int(backlights.len() as i64)),
            ("backlights", backlights_json),
            ("ddcAvailable", Json::Bool(ddc_available)),
            ("ddcDisplayCount", Json::Int(ddc_count)),
            ("ddcReason", Json::String(ddc_reason)),
            ("details", Json::String("No backlight device".to_string())),
            ("tooltip", Json::String("Brightness status unavailable".to_string())),
            ("capability", json::capability(true, true, false, "not-required", Some("device-unavailable"))),
        ]);
    };

    const ICONS: [&str; 7] = ["󰃚", "󰃛", "󰃜", "󰃝", "󰃞", "󰃟", "󰃠"];
    let icon = ICONS[((percent / 17) as usize).min(6)];
    let blue_mode = blue_light_mode();
    let blue_active = evaluate_hyprsunset_schedule(&blue_mode);
    let details = format!(
        "Brightness: {percent}%\nBlue light: {blue_mode} {}",
        if blue_active { "active" } else { "inactive" }
    );
    let can_change = command_exists("brightnessctl");

    Json::obj([
        ("icon", Json::String(icon.to_string())),
        ("percent", Json::Int(percent)),
        ("blueLightMode", Json::String(blue_mode)),
        ("blueLightActive", Json::Bool(blue_active)),
        ("device", Json::String(device)),
        ("backlightCount", Json::Int(backlights.len() as i64)),
        ("backlights", backlights_json),
        ("ddcAvailable", Json::Bool(ddc_available)),
        ("ddcDisplayCount", Json::Int(ddc_count)),
        ("ddcReason", Json::String(ddc_reason)),
        ("details", Json::String(details.clone())),
        ("tooltip", Json::String(details)),
        ("capability", json::capability(true, true, can_change, if can_change { "granted" } else { "not-required" }, None)),
    ])
}

pub fn touchpad_status() -> Json {
    let mut devices = Vec::new();
    let mut discovery_ok = true;
    if let Ok(explicit) = env::var("TOUCHPAD_DEVICE") {
        if !explicit.is_empty() {
            devices.push(explicit);
        }
    } else if let Some(dev_json) = hypr::query_json("j/devices") {
        if let Some(mice) = dev_json.get("mice").and_then(Json::as_array) {
            for mouse in mice {
                if let Some(name) = mouse.get_str("name") {
                    let lower = name.to_lowercase();
                    if lower.contains("touchpad") || lower.contains("trackpad") {
                        devices.push(name.to_string());
                    }
                }
            }
        }
    } else {
        discovery_ok = false;
    }

    if !discovery_ok {
        return Json::obj([
            ("icon", Json::String("󰟸".to_string())),
            ("class", Json::String("unavailable".to_string())),
            ("device", Json::String(String::new())),
            ("devices", Json::Array(Vec::new())),
            ("touchpadCount", Json::Int(0)),
            ("enabled", Json::Bool(false)),
            ("details", Json::String("Touchpad discovery unavailable".to_string())),
            ("tooltip", Json::String("Touchpad discovery unavailable".to_string())),
            ("capability", json::capability(false, false, false, "unknown", Some("command-unavailable"))),
        ]);
    }

    let enabled = fs::read_to_string(runtime_dir().join("quickshell-touchpad-enabled"))
        .ok()
        .map(|s| s.trim() != "false")
        .unwrap_or(true);
    let device = devices.first().cloned().unwrap_or_default();
    let count = devices.len() as i64;
    let devices_json = Json::Array(devices.into_iter().map(Json::String).collect());
    let (icon, class, label) = if enabled {
        ("󰟸", "enabled", "Touchpad enabled")
    } else {
        ("󰤳", "disabled", "Touchpad disabled")
    };
    let cap = if device.is_empty() {
        json::capability(true, true, false, "not-required", Some("device-unavailable"))
    } else {
        json::capability(true, true, true, "not-required", None)
    };

    Json::obj([
        ("icon", Json::String(icon.to_string())),
        ("class", Json::String(class.to_string())),
        ("device", Json::String(device)),
        ("devices", devices_json),
        ("touchpadCount", Json::Int(count)),
        ("enabled", Json::Bool(enabled)),
        ("details", Json::String(label.to_string())),
        ("tooltip", Json::String(label.to_string())),
        ("capability", cap),
    ])
}

fn duration_label(secs: i64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}h {m:02}m {s:02}s")
    } else if m > 0 {
        format!("{m}m {s:02}s")
    } else {
        format!("{s}s")
    }
}

pub fn caffeine_status(check_unit: bool) -> Json {
    let cap_ok = command_exists("hypridle")
        && command_exists("systemd-run")
        && command_exists("systemd-inhibit")
        && command_exists("systemctl");

    let mut deadline: i64 = 0;
    let mut mode = "off".to_string();
    if let Ok(bytes) = fs::read(state_dir().join("caffeine.json")) {
        if let Some(parsed) = json::parse(&bytes) {
            deadline = parsed.get_i64("deadline").unwrap_or(0);
            if let Some(m) = parsed.get_str("mode") {
                mode = m.to_string();
            }
        }
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let (active, remaining, label, mut class, mut tooltip) = if deadline == -1 {
        mode = "indefinite".to_string();
        (true, -1, "Indefinite".to_string(), "active".to_string(), "Awake indefinitely".to_string())
    } else if deadline > now {
        let rem = deadline - now;
        let lbl = duration_label(rem);
        (true, rem, lbl.clone(), "active".to_string(), format!("Awake for {lbl}"))
    } else {
        mode = "off".to_string();
        (false, 0, "Off".to_string(), "idle".to_string(), "Hypridle running".to_string())
    };

    let hypridle_running = cap_ok && process_running("hypridle");
    let inhibited = if cap_ok && (active || check_unit) {
        Command::new("systemctl")
            .args(["--user", "is-active", "--quiet", "blox-caffeine.service"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    } else {
        false
    };

    if active {
        if inhibited {
            tooltip.push_str("\nHypridle paused");
        } else if hypridle_running {
            class = "warning".to_string();
            tooltip.push_str("\nWarning: Awake inhibitor is not active");
        } else {
            class = "warning".to_string();
            tooltip.push_str("\nWarning: Hypridle is not running");
        }
    } else if hypridle_running {
        tooltip.push_str("\nHypridle active");
    } else {
        class = "warning".to_string();
        tooltip.push_str("\nWarning: Hypridle is not running");
    }

    let cap = if cap_ok {
        json::capability(true, true, true, "granted", None)
    } else {
        json::capability(false, false, false, "unknown", Some("command-unavailable"))
    };

    Json::obj([
        ("icon", Json::String("󰅶".to_string())),
        ("class", Json::String(class)),
        ("mode", Json::String(mode)),
        ("label", Json::String(label)),
        ("tooltip", Json::String(tooltip)),
        ("active", Json::Bool(active)),
        ("deadline", Json::Int(deadline)),
        ("remaining", Json::Int(remaining)),
        ("hypridleRunning", Json::Bool(hypridle_running)),
        ("inhibitActive", Json::Bool(inhibited)),
        ("reconciled", Json::Bool(false)),
        ("capability", cap),
    ])
}
