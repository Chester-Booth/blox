use std::collections::{BTreeMap, HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::hypr;
use crate::json::{self, Json};

const PICKER_CLASS: &str = "org.quickshell";

fn picker_kind(title: &str) -> Option<&'static str> {
    match title {
        "Blox Clipboard" => Some("clipboard"),
        "Blox Emoji Picker" => Some("emoji"),
        _ => None,
    }
}

fn state_path() -> PathBuf {
    let base = env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("HOME").unwrap_or_default()).join(".local/state"));
    base.join("blox/launcher-window-geometry.json")
}

fn ipc_script() -> Option<PathBuf> {
    if let Ok(explicit) = env::var("BLOX_IPC_SCRIPT") {
        if !explicit.is_empty() {
            return Some(PathBuf::from(explicit));
        }
    }
    let exe = env::current_exe().ok()?;
    // Installed/source layout: shell/native/qml/Blox/Services/bloxd -> shell/scripts/ipc.sh
    let candidate = exe.ancestors().nth(5)?.join("scripts/ipc.sh");
    candidate.exists().then_some(candidate)
}

fn load_state(path: &PathBuf) -> BTreeMap<String, Json> {
    fs::read(path)
        .ok()
        .and_then(|bytes| json::parse(&bytes))
        .and_then(|v| match v {
            Json::Object(map) => Some(map),
            _ => None,
        })
        .unwrap_or_default()
}

fn save_state(path: &PathBuf, state: &BTreeMap<String, Json>) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("tmp");
    let mut encoded = json::encode(&Json::Object(state.clone()));
    encoded.push('\n');
    if fs::write(&tmp, encoded).is_ok() {
        let _ = fs::rename(tmp, path);
    }
}

fn norm_addr(raw: &str) -> String {
    raw.strip_prefix("0x").unwrap_or(raw).to_string()
}

fn pair_i64(value: Option<&Json>) -> Option<(i64, i64)> {
    let arr = value?.as_array()?;
    if arr.len() != 2 {
        return None;
    }
    Some((arr[0].as_i64()?, arr[1].as_i64()?))
}

fn clients_map() -> HashMap<String, Json> {
    let mut out = HashMap::new();
    if let Some(Json::Array(items)) = hypr::query_json("j/clients") {
        for item in items {
            if let Some(addr) = item.get_str("address") {
                out.insert(norm_addr(addr), item);
            }
        }
    }
    out
}

fn cursor_pos() -> Option<(i64, i64)> {
    let pos = hypr::query_json("j/cursorpos")?;
    Some((pos.get_i64("x")?, pos.get_i64("y")?))
}

fn window_position(address: &str, desired: Option<(i64, i64)>) -> Option<(i64, i64)> {
    let clients = clients_map();
    let item = clients.get(address)?;
    let size = pair_i64(item.get("size"))?;
    let monitors = match hypr::query_json("j/monitors") {
        Some(Json::Array(list)) => list,
        _ => return None,
    };

    let monitor = desired
        .and_then(|(dx, dy)| {
            monitors.iter().find(|m| {
                let mx = m.get_i64("x").unwrap_or(0);
                let my = m.get_i64("y").unwrap_or(0);
                let mw = m.get_i64("width").unwrap_or(0);
                let mh = m.get_i64("height").unwrap_or(0);
                dx >= mx && dx < mx + mw && dy >= my && dy < my + mh
            })
        })
        .or_else(|| monitors.iter().find(|m| m.get_bool("focused") == Some(true)))
        .or_else(|| monitors.first())?;

    let left = monitor.get_i64("x").unwrap_or(0);
    let top = monitor.get_i64("y").unwrap_or(0);
    let right = left + monitor.get_i64("width").unwrap_or(0) - size.0;
    let bottom = top + monitor.get_i64("height").unwrap_or(0) - size.1;
    let (dx, dy) = desired.unwrap_or((right - 20, bottom - 20));
    Some((dx.clamp(left, right.max(left)), dy.clamp(top, bottom.max(top))))
}

fn restore(address: &str, kind: &str, state: &BTreeMap<String, Json>) -> bool {
    let desired = state.get(kind).and_then(|g| Some((g.get_i64("x")?, g.get_i64("y")?)));
    let Some((x, y)) = window_position(address, desired) else {
        return false;
    };
    let cmd = format!(
        "eval hl.dispatch(hl.dsp.window.move({{x={x},y={y},relative=false,window='address:0x{address}'}}))"
    );
    if hypr::request(&cmd).is_err() {
        return false;
    }
    let clients = clients_map();
    if let Some((ax, ay)) = clients.get(address).and_then(|c| pair_i64(c.get("at"))) {
        (ax - x).abs() <= 1 && (ay - y).abs() <= 1
    } else {
        false
    }
}

fn run_ipc(args: &[&str]) {
    let Some(script) = ipc_script() else { return };
    let _ = Command::new(script)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Event-driven Hyprland picker position persistence and outside-click close.
/// Blocks indefinitely on the Hyprland socket when idle (zero idle CPU, zero unsafe).
pub fn run() -> io::Result<()> {
    let mut stream = hypr::connect_events()?;
    let path = state_path();
    let mut state = load_state(&path);
    let mut tracked: HashMap<String, &'static str> = HashMap::new();
    let mut restore_until: HashMap<String, Instant> = HashMap::new();
    let mut ready: HashSet<String> = HashSet::new();
    let mut last_geometry: HashMap<String, (i64, i64)> = HashMap::new();
    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 65536];

    loop {
        // Block indefinitely when idle; wake every 50ms only while a picker is actively open.
        let timeout = if tracked.is_empty() {
            None
        } else {
            Some(Duration::from_millis(50))
        };
        stream.set_read_timeout(timeout)?;

        match stream.read(&mut chunk) {
            Ok(0) => return Ok(()),
            Ok(n) => buffer.extend_from_slice(&chunk[..n]),
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::TimedOut
                    || e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }

        while let Some(nl) = buffer.iter().position(|b| *b == b'\n') {
            let raw: Vec<u8> = buffer.drain(..=nl).collect();
            let line = String::from_utf8_lossy(&raw[..raw.len() - 1]);
            let Some((event, data)) = line.split_once(">>") else { continue };
            match event {
                "openwindow" => {
                    let mut parts = data.splitn(4, ',');
                    let addr = norm_addr(parts.next().unwrap_or(""));
                    let _ws = parts.next();
                    let class = parts.next().unwrap_or("");
                    let title = parts.next().unwrap_or("");
                    if class == PICKER_CLASS {
                        if let Some(kind) = picker_kind(title) {
                            tracked.insert(addr.clone(), kind);
                            restore_until.insert(addr.clone(), Instant::now() + Duration::from_millis(650));
                            if restore(&addr, kind, &state) {
                                run_ipc(&["launcher", "positioned", kind]);
                                ready.insert(addr);
                            }
                        }
                    }
                }
                "closewindow" => {
                    let addr = norm_addr(data);
                    if let Some(kind) = tracked.remove(&addr) {
                        let pos = last_geometry.remove(&addr).or_else(|| {
                            clients_map().get(&addr).and_then(|c| pair_i64(c.get("at")))
                        });
                        if let Some((x, y)) = pos {
                            state.insert(
                                kind.to_string(),
                                Json::obj([("x", Json::Int(x)), ("y", Json::Int(y))]),
                            );
                            save_state(&path, &state);
                        }
                        restore_until.remove(&addr);
                        ready.remove(&addr);
                    }
                }
                "custom" if data == "blox-picker-click" && !tracked.is_empty() => {
                    let live = clients_map();
                    let inside = cursor_pos()
                        .map(|(cx, cy)| {
                            tracked.keys().any(|addr| {
                                live.get(addr)
                                    .and_then(|c| Some((pair_i64(c.get("at"))?, pair_i64(c.get("size"))?)))
                                    .map(|((x, y), (w, h))| cx >= x && cx < x + w && cy >= y && cy < y + h)
                                    .unwrap_or(false)
                            })
                        })
                        .unwrap_or(false);
                    if !inside {
                        run_ipc(&["launcher", "close"]);
                    }
                }
                _ => {}
            }
        }

        if tracked.is_empty() {
            continue;
        }

        let live = clients_map();
        tracked.retain(|addr, _| live.contains_key(addr));
        restore_until.retain(|addr, _| tracked.contains_key(addr));
        ready.retain(|addr| tracked.contains_key(addr));
        let mut changed = false;
        for (addr, &kind) in &tracked {
            let Some(item) = live.get(addr) else { continue };
            if !ready.contains(addr) {
                if restore(addr, kind, &state)
                    || restore_until.get(addr).map(|t| Instant::now() >= *t).unwrap_or(true)
                {
                    run_ipc(&["launcher", "positioned", kind]);
                    ready.insert(addr.clone());
                }
                continue;
            }
            if let Some(geom) = pair_i64(item.get("at")) {
                if last_geometry.get(addr) != Some(&geom) {
                    last_geometry.insert(addr.clone(), geom);
                    state.insert(
                        kind.to_string(),
                        Json::obj([("x", Json::Int(geom.0)), ("y", Json::Int(geom.1))]),
                    );
                    changed = true;
                }
            }
        }
        if changed {
            save_state(&path, &state);
        }
    }
}
