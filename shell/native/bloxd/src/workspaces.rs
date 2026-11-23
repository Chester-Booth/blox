use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::hypr;
use crate::json::{self, Json};

const SPECIAL_WORKSPACE: &str = "special:magic";

const ICON_RULES: &[(&[&str], &str)] = &[
    (&["t3"], "T3"),
    (&["intellij", "idea"], ""),
    (&["code"], "󰨞"),
    (&["firefox"], "󰈹"),
    (&["zen"], ""),
    (&["chrome"], ""),
    (&["helium"], ""),
    (&["zen", "helium", "firefox", "chrome", "brave"], ""),
    (&["discord", "vesktop"], ""),
    (&["slack"], "󰒱"),
    (&["teams"], "󰊻"),
    (&["thunar", "dolphin", "nemo", "pcmanfm"], "󰉋"),
    (&["obsidian"], "󱞁"),
    (&["obs"], "󰕧"),
    (&["steam"], "󰓓"),
    (&["prism", "minecraft"], "󰍳"),
    (&["gimp"], ""),
    (&["electron"], ""),
    (&["drawing"], "󱇣"),
    (&["kitty", "wezterm", "alacritty", "foot"], ""),
];

#[derive(Clone, Default)]
struct DesktopEntry {
    desktop_id: String,
    name: String,
    icon_name: String,
}

/// Cached XDG .desktop entry resolver that only re-scans if directory mtimes change.
pub struct DesktopResolver {
    dirs: Vec<PathBuf>,
    mtimes: Vec<Option<SystemTime>>,
    index: HashMap<String, DesktopEntry>,
    loaded: bool,
}

impl DesktopResolver {
    pub fn new() -> Self {
        Self {
            dirs: desktop_entry_dirs(),
            mtimes: Vec::new(),
            index: HashMap::new(),
            loaded: false,
        }
    }

    fn current_mtimes(&self) -> Vec<Option<SystemTime>> {
        self.dirs
            .iter()
            .map(|d| fs::metadata(d).ok().and_then(|m| m.modified().ok()))
            .collect()
    }

    fn ensure_fresh(&mut self) {
        let now = self.current_mtimes();
        if self.loaded && now == self.mtimes {
            return;
        }
        self.index.clear();
        for dir in self.dirs.iter().rev() {
            let Ok(entries) = fs::read_dir(dir) else { continue };
            let mut files: Vec<PathBuf> = entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("desktop"))
                .collect();
            files.sort();
            for path in files {
                let Some((entry, wm_class)) = parse_desktop_file(&path) else { continue };
                let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
                let mut keys = vec![stem.clone()];
                if !wm_class.is_empty() {
                    keys.push(wm_class.to_lowercase());
                }
                if let Some((_, suffix)) = stem.rsplit_once('.') {
                    keys.push(suffix.to_string());
                }
                for key in keys {
                    self.index.insert(key, entry.clone());
                }
            }
        }
        self.mtimes = now;
        self.loaded = true;
    }

    fn resolve(&mut self, app_class: &str, title: &str) -> DesktopEntry {
        let raw = app_class.trim();
        if raw.is_empty() {
            return DesktopEntry {
                desktop_id: String::new(),
                name: if title.is_empty() { "Application".to_string() } else { title.to_string() },
                icon_name: String::new(),
            };
        }
        self.ensure_fresh();
        let lower = raw.to_lowercase();
        let mut candidates = vec![lower.clone()];
        if let Some((_, suffix)) = lower.rsplit_once('.') {
            candidates.push(suffix.to_string());
        }
        if let Some((prefix, _)) = lower.split_once('-') {
            candidates.push(prefix.to_string());
        }
        for candidate in candidates {
            if let Some(hit) = self.index.get(&candidate) {
                return DesktopEntry {
                    desktop_id: hit.desktop_id.clone(),
                    name: if hit.name.is_empty() { raw.to_string() } else { hit.name.clone() },
                    icon_name: hit.icon_name.clone(),
                };
            }
        }
        DesktopEntry {
            desktop_id: String::new(),
            name: raw.to_string(),
            icon_name: String::new(),
        }
    }
}

fn desktop_entry_dirs() -> Vec<PathBuf> {
    let mut raw_dirs = Vec::new();
    let xdg_data_home = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env::var("HOME").unwrap_or_default()).join(".local/share"));
    raw_dirs.push(xdg_data_home.join("applications"));
    raw_dirs.push(xdg_data_home.join("flatpak/exports/share/applications"));
    let xdg_data_dirs = env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".to_string());
    for part in xdg_data_dirs.split(':') {
        if !part.is_empty() {
            raw_dirs.push(PathBuf::from(part).join("applications"));
        }
    }
    raw_dirs.push(PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    let mut out = Vec::new();
    for dir in raw_dirs {
        if dir.is_dir() && !out.contains(&dir) {
            out.push(dir);
        }
    }
    out
}

fn parse_desktop_file(path: &Path) -> Option<(DesktopEntry, String)> {
    let text = fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let mut entry = DesktopEntry {
        desktop_id: path.file_stem()?.to_str()?.to_string(),
        ..Default::default()
    };
    let mut wm_class = String::new();
    for line in text.lines() {
        let s = line.trim();
        if s.is_empty() || s.starts_with('#') {
            continue;
        }
        if s.starts_with('[') {
            if in_entry {
                break;
            }
            in_entry = s == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((k, v)) = s.split_once('=') else { continue };
        let val = v.trim();
        match k.trim() {
            "Name" if entry.name.is_empty() => entry.name = val.to_string(),
            "Icon" if entry.icon_name.is_empty() => entry.icon_name = val.to_string(),
            "StartupWMClass" if wm_class.is_empty() => wm_class = val.to_string(),
            "Hidden" if val.eq_ignore_ascii_case("true") => return None,
            _ => {}
        }
    }
    Some((entry, wm_class))
}

fn app_name(client: &Json) -> &str {
    client
        .get_str("class")
        .filter(|s| !s.is_empty())
        .or_else(|| client.get_str("initialClass"))
        .unwrap_or("")
}

fn icon_match(value: &str) -> (usize, &'static str) {
    let lower = value.to_lowercase();
    for (idx, (terms, icon)) in ICON_RULES.iter().enumerate() {
        if terms.iter().any(|t| lower.contains(t)) {
            return (idx, icon);
        }
    }
    (ICON_RULES.len(), "󰻃")
}

/// Assemble Hyprland workspace, per-monitor fullscreen, and grouped desktop-entry app metadata.
pub fn collect_status(resolver: &mut DesktopResolver) -> Json {
    let hypr_available = hypr::is_available();
    let active_val = hypr::query_json("j/activeworkspace");
    let clients_val = hypr::query_json("j/clients");
    let monitors_val = hypr::query_json("j/monitors");
    let workspaces_val = hypr::query_json("j/workspaces");
    let hypr_ready = active_val.is_some() && clients_val.is_some() && monitors_val.is_some();

    let active_id = active_val.as_ref().and_then(|v| v.get_i64("id"));
    let active_name = active_val.as_ref().and_then(|v| v.get_str("name")).unwrap_or("");
    let clients = clients_val.as_ref().and_then(Json::as_array).map(Vec::as_slice).unwrap_or(&[]);
    let monitors = monitors_val.as_ref().and_then(Json::as_array).map(Vec::as_slice).unwrap_or(&[]);
    let workspaces = workspaces_val.as_ref().and_then(Json::as_array).map(Vec::as_slice).unwrap_or(&[]);

    let mut ws_meta: HashMap<i64, &Json> = HashMap::new();
    for ws in workspaces {
        if let Some(id) = ws.get_i64("id") {
            ws_meta.insert(id, ws);
        }
    }

    let mut monitor_active_ids: HashMap<String, i64> = HashMap::new();
    let mut monitor_summary: BTreeMap<String, Json> = BTreeMap::new();
    let mut default_monitor = String::new();
    let mut special_active = active_name == SPECIAL_WORKSPACE;
    let mut focused_mon_special: Option<bool> = None;
    let mut any_mon_special = false;

    for mon in monitors {
        if mon.get_bool("disabled") == Some(true) {
            continue;
        }
        let m_name = mon.get_str("name").unwrap_or("").to_string();
        if default_monitor.is_empty() {
            default_monitor = m_name.clone();
        }
        let m_active_id = mon.get("activeWorkspace").and_then(|w| w.get_i64("id"));
        if let Some(mid) = m_active_id {
            monitor_active_ids.insert(m_name.clone(), mid);
        }
        let has_fs = m_active_id
            .and_then(|mid| ws_meta.get(&mid))
            .and_then(|m| m.get_bool("hasfullscreen"))
            .unwrap_or(false);
        let focused = mon.get_bool("focused").unwrap_or(false);
        let sp = mon.get("specialWorkspace").and_then(|w| w.get_str("name")) == Some(SPECIAL_WORKSPACE);
        if focused {
            focused_mon_special = Some(sp);
        }
        if sp {
            any_mon_special = true;
        }
        monitor_summary.insert(
            m_name,
            Json::obj([
                ("activeWorkspaceId", m_active_id.map(Json::Int).unwrap_or(Json::Null)),
                ("focused", Json::Bool(focused)),
                ("hasFullscreen", Json::Bool(has_fs)),
            ]),
        );
    }
    if !special_active {
        special_active = focused_mon_special.unwrap_or(any_mon_special);
    }

    let mut by_ws: HashMap<i64, Vec<&Json>> = HashMap::new();
    let mut urgent_ws: BTreeSet<i64> = BTreeSet::new();
    let mut special_count: usize = 0;

    for client in clients {
        let ws = client.get("workspace");
        if ws.and_then(|w| w.get_str("name")) == Some(SPECIAL_WORKSPACE) {
            special_count += 1;
        }
        if let Some(ws_id) = ws.and_then(|w| w.get_i64("id")) {
            by_ws.entry(ws_id).or_default().push(client);
            if client.get_bool("urgent") == Some(true) {
                urgent_ws.insert(ws_id);
            }
        }
    }

    let mut ws_ids: BTreeSet<i64> = (1..=5).collect();
    for (&ws_id, list) in &by_ws {
        if ws_id > 5 && !list.is_empty() {
            ws_ids.insert(ws_id);
        }
    }
    for &mid in monitor_active_ids.values() {
        if mid > 0 {
            ws_ids.insert(mid);
        }
    }

    let mut items = Vec::with_capacity(ws_ids.len());
    for ws_id in ws_ids {
        let ws_clients = by_ws.get(&ws_id).map(Vec::as_slice).unwrap_or(&[]);
        let meta = ws_meta.get(&ws_id).copied();
        let owner_mon = meta
            .and_then(|m| m.get_str("monitor"))
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .or_else(|| {
                monitor_active_ids
                    .iter()
                    .find(|&(_, &mid)| mid == ws_id)
                    .map(|(k, _)| k.clone())
            })
            .unwrap_or_else(|| default_monitor.clone());
        let active_on_mon = !owner_mon.is_empty() && monitor_active_ids.get(&owner_mon) == Some(&ws_id);
        let has_fs = meta.and_then(|m| m.get_bool("hasfullscreen")).unwrap_or(false);

        let chosen = ws_clients.iter().copied().min_by_key(|c| {
            (icon_match(app_name(c)).0, c.get_i64("focusHistoryID").unwrap_or(999_999))
        });
        let urgent_client = ws_clients.iter().copied().find(|c| c.get_bool("urgent") == Some(true));

        let mut ordered: Vec<&Json> = ws_clients.to_vec();
        ordered.sort_by_key(|c| {
            (
                if c.get_bool("urgent") == Some(true) { 0 } else { 1 },
                icon_match(app_name(c)).0,
                c.get_i64("focusHistoryID").unwrap_or(999_999),
            )
        });
        let mut group_order: Vec<String> = Vec::new();
        let mut groups: HashMap<String, (String, DesktopEntry, &'static str, i64, bool, Vec<Json>)> = HashMap::new();
        for c in ordered {
            let cls = app_name(c);
            let title = c.get_str("title").unwrap_or("");
            let key = if !cls.is_empty() { cls } else if !title.is_empty() { title } else { "window" }.to_lowercase();
            let entry = groups.entry(key.clone()).or_insert_with(|| {
                group_order.push(key);
                (cls.to_string(), resolver.resolve(cls, title), icon_match(cls).1, 0, false, Vec::new())
            });
            entry.3 += 1;
            if c.get_bool("urgent") == Some(true) {
                entry.4 = true;
            }
            if let Some(addr) = c.get_str("address") {
                if !addr.is_empty() {
                    entry.5.push(Json::String(addr.to_string()));
                }
            }
        }
        let apps = Json::Array(
            group_order
                .into_iter()
                .filter_map(|k| groups.remove(&k))
                .map(|(cls, info, glyph, count, urg, addrs)| {
                    Json::obj([
                        ("appClass", Json::String(cls)),
                        ("desktopId", Json::String(info.desktop_id)),
                        ("name", Json::String(info.name)),
                        ("iconName", Json::String(info.icon_name)),
                        ("glyph", Json::String(glyph.to_string())),
                        ("count", Json::Int(count)),
                        ("urgent", Json::Bool(urg)),
                        ("addresses", Json::Array(addrs)),
                    ])
                })
                .collect(),
        );

        let app = chosen.map(app_name).unwrap_or("");
        let title = chosen.and_then(|c| c.get_str("title")).unwrap_or("");
        let is_urgent = urgent_ws.contains(&ws_id);
        let icon = if is_urgent {
            "󰗖"
        } else if chosen.is_some() {
            icon_match(app).1
        } else {
            "󰄰"
        };
        let tooltip = if !app.is_empty() || !title.is_empty() {
            format!("Workspace {ws_id}\n{app}\n{title}")
        } else {
            format!("Workspace {ws_id}")
        };

        items.push(Json::obj([
            ("id", Json::Int(ws_id)),
            ("monitor", Json::String(owner_mon)),
            ("active", Json::Bool(active_id == Some(ws_id))),
            ("activeOnMonitor", Json::Bool(active_on_mon)),
            ("hasFullscreen", Json::Bool(has_fs)),
            ("urgent", Json::Bool(is_urgent)),
            ("urgentAddress", Json::String(urgent_client.and_then(|c| c.get_str("address")).unwrap_or("").to_string())),
            ("empty", Json::Bool(ws_clients.is_empty())),
            ("windowCount", Json::Int(ws_clients.len() as i64)),
            ("apps", apps),
            ("icon", Json::String(icon.to_string())),
            ("tooltip", Json::String(tooltip)),
        ]));
    }

    let special_tooltip = if special_count > 0 {
        format!("Special workspace\n{special_count} window(s)")
    } else {
        "Special workspace".to_string()
    };
    let cap_reason = if hypr_ready {
        None
    } else if hypr_available {
        Some("query-failed")
    } else {
        Some("command-unavailable")
    };

    Json::obj([
        ("main", Json::Array(items)),
        ("monitors", Json::Object(monitor_summary)),
        ("special", Json::obj([
            ("active", Json::Bool(special_active)),
            ("occupied", Json::Bool(special_count > 0)),
            ("icon", Json::String(if special_active { "󰘻" } else { "󰘼" }.to_string())),
            ("tooltip", Json::String(special_tooltip)),
        ])),
        ("capability", json::capability(hypr_available, hypr_ready, false, "not-required", cap_reason)),
    ])
}
