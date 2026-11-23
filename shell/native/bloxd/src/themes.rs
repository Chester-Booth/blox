use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::json::{self, Json};
use crate::sha256;

const SOURCE_REQUIRED_TOP_LEVEL: &[&str] = &["schema_version", "id", "name", "colours", "wallpaper"];
const SOURCE_REQUIRED_COLOURS: &[&str] = &[
    "background",
    "surface",
    "surface_alt",
    "foreground",
    "muted",
    "accent",
    "danger",
    "success",
    "warning",
    "info",
    "mauve",
    "teal",
    "selection_background",
    "selection_foreground",
    "border",
];
const SOURCE_REQUIRED_WALLPAPER: &[&str] = &["path", "fit"];

fn expand_home(raw: &str) -> PathBuf {
    if raw == "~" {
        if let Ok(home) = env::var("HOME") {
            return PathBuf::from(home);
        }
    } else if let Some(rest) = raw.strip_prefix("~/") {
        if let Ok(home) = env::var("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(raw)
}

/// Normalise a path without requiring every component to exist on disk.
fn normalise_path(path: &Path) -> PathBuf {
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir().unwrap_or_else(|_| PathBuf::from("/")).join(path)
    };
    if let Ok(canon) = fs::canonicalize(&abs) {
        return canon;
    }
    let mut out = PathBuf::new();
    for comp in abs.components() {
        match comp {
            Component::Prefix(p) => out.push(p.as_os_str()),
            Component::RootDir => out.push(comp.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(part) => out.push(part),
        }
    }
    out
}

fn is_valid_themes_dir(dir: &Path) -> bool {
    dir.join("defaults/v1.json").is_file() && dir.join("schema/theme.schema.json").is_file()
}

fn resolve_themes_dir() -> Result<PathBuf, String> {
    if let Ok(configured) = env::var("BLOX_DATA_DIR") {
        if !configured.is_empty() {
            let p = expand_home(&configured);
            if is_valid_themes_dir(&p) {
                return Ok(normalise_path(&p));
            }
        }
    }
    if let Ok(exe) = env::current_exe() {
        let mut cur = exe.parent();
        for _ in 0..7 {
            let Some(dir) = cur else { break };
            let candidate = dir.join("themes");
            if is_valid_themes_dir(&candidate) {
                return Ok(normalise_path(&candidate));
            }
            if is_valid_themes_dir(dir) {
                return Ok(normalise_path(dir));
            }
            cur = dir.parent();
        }
    }
    if let Ok(install_root) = env::var("BLOX_INSTALL_ROOT") {
        if !install_root.is_empty() {
            let candidate = expand_home(&install_root).join("themes");
            if is_valid_themes_dir(&candidate) {
                return Ok(normalise_path(&candidate));
            }
        }
    }
    if let Ok(home) = env::var("HOME") {
        let candidate = PathBuf::from(home).join(".local/share/blox/themes");
        if is_valid_themes_dir(&candidate) {
            return Ok(normalise_path(&candidate));
        }
    }
    for sys_path in ["/usr/local/share/blox", "/usr/share/blox"] {
        let p = Path::new(sys_path);
        if is_valid_themes_dir(p) {
            return Ok(p.to_path_buf());
        }
    }
    Err("could not locate Blox themes directory".to_string())
}

fn user_theme_library() -> PathBuf {
    if let Ok(override_dir) = env::var("BLOX_USER_DATA_DIR") {
        if !override_dir.is_empty() {
            return expand_home(&override_dir);
        }
    }
    let base = match env::var("XDG_DATA_HOME") {
        Ok(val) if !val.is_empty() => expand_home(&val),
        _ => PathBuf::from(env::var("HOME").unwrap_or_default()).join(".local/share"),
    };
    base.join("blox-user")
}

fn is_builtin_path(path: &Path, builtin_dir: &Path) -> bool {
    let norm_path = normalise_path(path);
    let norm_builtin = normalise_path(builtin_dir);
    norm_path.starts_with(&norm_builtin)
}

fn resolve_wallpaper_path(
    value: &str,
    source_path: &Path,
    themes_dir: &Path,
    builtin_dir: &Path,
) -> PathBuf {
    let path = expand_home(value);
    if path.is_absolute() {
        return normalise_path(&path);
    }
    let mut parts = path.components();
    let is_builtin_wp = matches!(
        (parts.next(), parts.next()),
        (Some(Component::Normal(a)), Some(Component::Normal(b)))
            if a == "wallpapers" && b == "builtin"
    ) && !path.components().any(|c| matches!(c, Component::ParentDir));
    if is_builtin_wp {
        return normalise_path(&themes_dir.join(&path));
    }
    let mut root = themes_dir.to_path_buf();
    let norm_source = normalise_path(source_path);
    let norm_builtin = normalise_path(builtin_dir);
    if !norm_source.starts_with(&norm_builtin) {
        if let Some(repo) = themes_dir.parent() {
            let norm_repo = normalise_path(repo);
            if norm_source.starts_with(&norm_repo) {
                root = norm_repo;
            } else if let Some(parent) = norm_source.parent() {
                root = parent.to_path_buf();
            }
        } else if let Some(parent) = norm_source.parent() {
            root = parent.to_path_buf();
        }
    }
    normalise_path(&root.join(&path))
}

fn load_json_file(path: &Path) -> Result<(Vec<u8>, Json), String> {
    let bytes = fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let parsed = json::parse(&bytes).ok_or_else(|| format!("{}: invalid JSON", path.display()))?;
    Ok((bytes, parsed))
}

fn deep_merge(base: &Json, overlay: &Json) -> Json {
    match (base, overlay) {
        (Json::Object(b), Json::Object(o)) => {
            let mut merged = b.clone();
            for (k, v) in o {
                let next = match merged.get(k) {
                    Some(existing) => deep_merge(existing, v),
                    None => v.clone(),
                };
                merged.insert(k.clone(), next);
            }
            Json::Object(merged)
        }
        (_, other) => other.clone(),
    }
}

fn is_hex_colour(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(|b| b.is_ascii_hexdigit())
}

fn apply_theme_defaults(theme: &Json, defaults_doc: &Json) -> Result<Json, String> {
    let Some(obj) = theme.as_object() else {
        return Err("theme root must be a JSON object".to_string());
    };
    for &key in SOURCE_REQUIRED_TOP_LEVEL {
        if !obj.contains_key(key) {
            return Err(format!("missing required property {key}"));
        }
    }
    if !matches!(obj.get("schema_version"), Some(Json::Int(1))) {
        return Err("unsupported theme schema_version".to_string());
    }
    let Some(src_colours) = obj.get("colours").and_then(Json::as_object) else {
        return Err("colours must be an object".to_string());
    };
    for &key in SOURCE_REQUIRED_COLOURS {
        match src_colours.get(key).and_then(Json::as_str) {
            Some(v) if is_hex_colour(v) => {}
            _ => return Err(format!("invalid colour {key}")),
        }
    }
    let Some(src_wp) = obj.get("wallpaper").and_then(Json::as_object) else {
        return Err("wallpaper must be an object".to_string());
    };
    for &key in SOURCE_REQUIRED_WALLPAPER {
        if !src_wp.contains_key(key) {
            return Err(format!("wallpaper missing {key}"));
        }
    }

    let defaults = defaults_doc
        .get("theme")
        .and_then(Json::as_object)
        .ok_or("defaults missing theme")?;
    let def_colours = defaults
        .get("colours")
        .and_then(Json::as_object)
        .ok_or("defaults missing colours")?;

    let get_c = |k: &str| -> Result<Json, String> {
        def_colours
            .get(k)
            .cloned()
            .ok_or_else(|| format!("defaults missing colour {k}"))
    };

    let mut colours_map = BTreeMap::new();
    for (dst, src) in [
        ("background", "background"),
        ("surface", "surface"),
        ("surface_alt", "surface_alt"),
        ("foreground", "foreground"),
        ("muted", "muted"),
        ("danger", "red"),
        ("success", "green"),
        ("warning", "yellow"),
        ("accent", "accent"),
        ("info", "blue"),
        ("mauve", "mauve"),
        ("teal", "teal"),
        ("selection_background", "selection_background"),
        ("selection_foreground", "selection_foreground"),
        ("border", "border"),
    ] {
        colours_map.insert(dst.to_string(), get_c(src)?);
    }

    let mut shell = defaults.get("shell").cloned().ok_or("defaults missing shell")?;
    if let Json::Object(ref mut shell_obj) = shell {
        if let Some(Json::Object(ref mut bar_obj)) = shell_obj.get_mut("bar") {
            bar_obj.remove("reset_items");
        }
    }

    let mut fragment = BTreeMap::new();
    fragment.insert("schema_version".to_string(), Json::Int(1));
    fragment.insert("id".to_string(), defaults.get("id").cloned().unwrap_or(Json::Null));
    fragment.insert(
        "name".to_string(),
        defaults
            .get("name")
            .or_else(|| defaults.get("id"))
            .cloned()
            .unwrap_or(Json::Null),
    );
    fragment.insert(
        "variant".to_string(),
        defaults.get("variant").cloned().unwrap_or(Json::Null),
    );
    fragment.insert("colours".to_string(), Json::Object(colours_map));
    for key in [
        "fonts",
        "shape",
        "hyprland",
        "wallpaper",
        "terminal",
        "stylus",
        "targets",
        "gtk",
        "icons",
        "cursor",
    ] {
        if let Some(v) = defaults.get(key) {
            fragment.insert(key.to_string(), v.clone());
        }
    }
    fragment.insert("shell".to_string(), shell);
    if let Some(widgets) = defaults_doc.get("widgets") {
        fragment.insert("widgets".to_string(), widgets.clone());
    }

    let mut resolved = deep_merge(&Json::Object(fragment), theme);
    if let Some(src_widgets) = obj.get("widgets") {
        if let Json::Object(ref mut res_obj) = resolved {
            res_obj.insert("widgets".to_string(), src_widgets.clone());
        }
    }
    Ok(resolved)
}

fn resolved_bar_items(bar: Option<&Json>, defaults_doc: &Json) -> Result<Vec<Json>, String> {
    let default_items = defaults_doc
        .get("theme")
        .and_then(|t| t.get("shell"))
        .and_then(|s| s.get("bar"))
        .and_then(|b| b.get("items"))
        .and_then(Json::as_array)
        .ok_or("defaults missing bar items")?;

    let mut overrides: BTreeMap<String, BTreeMap<String, Json>> = BTreeMap::new();
    if let Some(items) = bar.and_then(|b| b.get("items")).and_then(Json::as_array) {
        for item in items {
            let Some(map) = item.as_object() else { continue };
            let Some(id) = map.get("id").and_then(Json::as_str) else { continue };
            overrides.insert(id.to_string(), map.clone());
        }
    }
    if overrides.contains_key("tray") && !overrides.contains_key("application-tray") {
        if let Some(mut legacy) = overrides.remove("tray") {
            legacy.insert("id".to_string(), Json::String("application-tray".to_string()));
            overrides.insert("application-tray".to_string(), legacy);
        }
    }

    let mut items: Vec<BTreeMap<String, Json>> = Vec::with_capacity(default_items.len());
    for def in default_items {
        let mut map = def.as_object().cloned().unwrap_or_default();
        if let Some(id) = map.get("id").and_then(Json::as_str).map(str::to_string) {
            if let Some(ov) = overrides.get(&id) {
                for (k, v) in ov {
                    map.insert(k.clone(), v.clone());
                }
            }
        }
        items.push(map);
    }

    let tray_pos = items
        .iter()
        .position(|m| m.get("id").and_then(Json::as_str) == Some("tray"))
        .ok_or("missing tray item")?;
    if items[tray_pos].get("region").and_then(Json::as_str) == Some("hidden") {
        items[tray_pos].insert("region".to_string(), Json::String("end".to_string()));
    }
    let tray_region = items[tray_pos]
        .get("region")
        .and_then(Json::as_str)
        .unwrap_or("end")
        .to_string();

    let mut visible_indices: Vec<usize> = items
        .iter()
        .enumerate()
        .filter(|(_, m)| m.get("region").and_then(Json::as_str) == Some(tray_region.as_str()))
        .map(|(i, _)| i)
        .collect();
    visible_indices.sort_by_key(|&i| items[i].get("order").and_then(Json::as_i64).unwrap_or(0));

    let tray_idx_in_vis = visible_indices
        .iter()
        .position(|&i| i == tray_pos)
        .ok_or("tray not in visible region")?;
    visible_indices.remove(tray_idx_in_vis);
    if tray_region == "start" {
        visible_indices.push(tray_pos);
    } else if tray_region == "end" || (tray_idx_in_vis as f64) < (visible_indices.len() as f64 + 1.0) / 2.0 {
        visible_indices.insert(0, tray_pos);
    } else {
        visible_indices.push(tray_pos);
    }
    for (order, &idx) in visible_indices.iter().enumerate() {
        items[idx].insert("order".to_string(), Json::Int(order as i64));
    }

    let app_tray_pos = items
        .iter()
        .position(|m| m.get("id").and_then(Json::as_str) == Some("application-tray"))
        .ok_or("missing application-tray item")?;
    items[app_tray_pos].insert("region".to_string(), Json::String("hidden".to_string()));

    let mut hidden_indices: Vec<usize> = items
        .iter()
        .enumerate()
        .filter(|&(i, m)| {
            i != app_tray_pos && m.get("region").and_then(Json::as_str) == Some("hidden")
        })
        .map(|(i, _)| i)
        .collect();
    hidden_indices.sort_by_key(|&i| items[i].get("order").and_then(Json::as_i64).unwrap_or(0));

    let tray_opens_forward = if tray_region == "start" {
        true
    } else if tray_region == "centre" {
        let mut centre_indices: Vec<usize> = items
            .iter()
            .enumerate()
            .filter(|(_, m)| m.get("region").and_then(Json::as_str) == Some("centre"))
            .map(|(i, _)| i)
            .collect();
        centre_indices.sort_by_key(|&i| items[i].get("order").and_then(Json::as_i64).unwrap_or(0));
        centre_indices
            .last()
            .map(|&i| items[i].get("id").and_then(Json::as_str) == Some("tray"))
            .unwrap_or(false)
    } else {
        false
    };

    if tray_opens_forward {
        hidden_indices.push(app_tray_pos);
    } else {
        hidden_indices.insert(0, app_tray_pos);
    }
    for (order, &idx) in hidden_indices.iter().enumerate() {
        items[idx].insert("order".to_string(), Json::Int(order as i64));
    }

    Ok(items.into_iter().map(Json::Object).collect())
}

fn inherited_paths(source: &Json, resolved: &Json, prefix: &str, out: &mut Vec<Json>) {
    let Some(res_obj) = resolved.as_object() else {
        return;
    };
    let src_obj = source.as_object();
    for (key, value) in res_obj {
        let path = if prefix.is_empty() {
            key.clone()
        } else {
            format!("{prefix}.{key}")
        };
        match src_obj.and_then(|m| m.get(key)) {
            None => out.push(Json::String(path)),
            Some(src_val) if value.as_object().is_some() && src_val.as_object().is_some() => {
                inherited_paths(src_val, value, &path, out);
            }
            Some(_) => {}
        }
    }
}

fn sorted_json_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json") && p.is_file())
        .collect();
    files.sort();
    files
}

fn envelope(command: &str, data: Json) -> Json {
    Json::obj([
        ("api_version", Json::Int(1)),
        ("command", Json::String(command.to_string())),
        ("ok", Json::Bool(true)),
        ("status", Json::String("ok".to_string())),
        ("data", data),
        ("warnings", Json::Array(Vec::new())),
        ("errors", Json::Array(Vec::new())),
    ])
}

fn count_enabled_widgets(widgets: &Json) -> Result<i64, String> {
    let obj = widgets.as_object().ok_or("widgets must be an object")?;
    if !matches!(obj.get("schemaVersion"), Some(Json::Int(1))) {
        return Err("unsupported widget schemaVersion".to_string());
    }
    let arr = obj
        .get("widgets")
        .and_then(Json::as_array)
        .ok_or("widgets.widgets must be an array")?;
    let mut count = 0_i64;
    for item in arr {
        let m = item.as_object().ok_or("widget item must be object")?;
        if m.get("enabled").and_then(Json::as_bool).unwrap_or(false) {
            count += 1;
        }
    }
    Ok(count)
}

/// Fast read-only equivalent of `themectl list --json`.
pub fn cmd_list() -> Result<String, String> {
    let themes_dir = resolve_themes_dir()?;
    let builtin_dir = themes_dir.join("builtin");
    let (_, defaults_doc) = load_json_file(&themes_dir.join("defaults/v1.json"))?;

    let mut paths = sorted_json_files(&builtin_dir);
    paths.extend(sorted_json_files(&user_theme_library().join("themes")));

    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut entries: Vec<Json> = Vec::with_capacity(paths.len());

    for path in paths {
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        let builtin = is_builtin_path(&path, &builtin_dir);
        let parsed = load_json_file(&path).and_then(|(bytes, raw)| {
            let resolved = apply_theme_defaults(&raw, &defaults_doc)?;
            let widget_count = count_enabled_widgets(
                resolved.get("widgets").ok_or("missing widgets")?,
            )?;
            let bar_items = resolved_bar_items(
                resolved.get("shell").and_then(|s| s.get("bar")),
                &defaults_doc,
            )?;
            Ok((bytes, resolved, widget_count, bar_items))
        });

        match parsed {
            Ok((bytes, resolved, widget_count, bar_items)) => {
                let theme_id = resolved
                    .get_str("id")
                    .map(str::to_string)
                    .unwrap_or_else(|| stem.clone());
                if !seen.insert(theme_id.clone()) {
                    continue;
                }
                let name = resolved
                    .get_str("name")
                    .map(str::to_string)
                    .unwrap_or(stem);
                let variant = resolved.get("variant").cloned().unwrap_or(Json::Null);
                let wp_raw = resolved
                    .get("wallpaper")
                    .and_then(|w| w.get_str("path"))
                    .unwrap_or("");
                let wp_resolved = if wp_raw.is_empty() {
                    String::new()
                } else {
                    resolve_wallpaper_path(wp_raw, &path, &themes_dir, &builtin_dir)
                        .to_string_lossy()
                        .into_owned()
                };
                let fonts = resolved.get("fonts");
                let bar_pos = resolved
                    .get("shell")
                    .and_then(|s| s.get("bar"))
                    .and_then(|b| b.get_str("position"))
                    .unwrap_or("left")
                    .to_string();
                let preview = Json::obj([
                    (
                        "colours",
                        resolved
                            .get("colours")
                            .cloned()
                            .unwrap_or_else(|| Json::Object(BTreeMap::new())),
                    ),
                    ("wallpaper", Json::String(wp_resolved)),
                    ("widget_count", Json::Int(widget_count)),
                    (
                        "fonts",
                        Json::obj([
                            (
                                "ui",
                                Json::String(
                                    fonts.and_then(|f| f.get_str("ui")).unwrap_or("").to_string(),
                                ),
                            ),
                            (
                                "mono",
                                Json::String(
                                    fonts
                                        .and_then(|f| f.get_str("mono"))
                                        .unwrap_or("")
                                        .to_string(),
                                ),
                            ),
                            (
                                "panel",
                                Json::String(
                                    fonts
                                        .and_then(|f| f.get_str("panel"))
                                        .unwrap_or("")
                                        .to_string(),
                                ),
                            ),
                        ]),
                    ),
                    (
                        "bar",
                        Json::obj([
                            ("position", Json::String(bar_pos)),
                            ("items", Json::Array(bar_items)),
                        ]),
                    ),
                ]);
                entries.push(Json::obj([
                    ("id", Json::String(theme_id)),
                    ("name", Json::String(name)),
                    ("variant", variant),
                    ("path", Json::String(path.to_string_lossy().into_owned())),
                    ("builtin", Json::Bool(builtin)),
                    ("source_sha256", Json::String(sha256::hex(&bytes))),
                    ("preview", preview),
                ]));
            }
            Err(_) => {
                entries.push(Json::obj([
                    ("id", Json::String(stem.clone())),
                    ("name", Json::String(stem)),
                    ("variant", Json::Null),
                    ("path", Json::String(path.to_string_lossy().into_owned())),
                    ("builtin", Json::Bool(builtin)),
                    ("invalid", Json::Bool(true)),
                ]));
            }
        }
    }

    Ok(json::encode(&envelope("list", Json::Array(entries))))
}

/// Fast read-only equivalent of `themectl show <reference> --json`.
/// Fails closed on inline JSON or invalid themes so callers fall back to Python validation.
pub fn cmd_show(reference: &str) -> Result<String, String> {
    if reference.trim_start().starts_with('{') {
        return Err("inline JSON requires Python validator".to_string());
    }
    let themes_dir = resolve_themes_dir()?;
    let builtin_dir = themes_dir.join("builtin");
    let (_, defaults_doc) = load_json_file(&themes_dir.join("defaults/v1.json"))?;

    let candidate = expand_home(reference);
    let path = if candidate.is_file() || reference.ends_with(".json") || reference.contains('/') {
        candidate
    } else {
        let built_in = builtin_dir.join(format!("{reference}.json"));
        if built_in.is_file() {
            built_in
        } else {
            let imported = user_theme_library()
                .join("themes")
                .join(format!("{reference}.json"));
            if imported.is_file() {
                imported
            } else {
                built_in
            }
        }
    };
    if !path.is_file() {
        return Err(format!("theme not found: {reference}"));
    }

    let (_, source) = load_json_file(&path)?;
    let resolved = apply_theme_defaults(&source, &defaults_doc)?;

    // Reject duplicate bar item IDs so Python reports full validation errors.
    if let Some(items) = resolved
        .get("shell")
        .and_then(|s| s.get("bar"))
        .and_then(|b| b.get("items"))
        .and_then(Json::as_array)
    {
        let mut ids = BTreeSet::new();
        for item in items {
            let Some(id) = item.get_str("id") else {
                return Err("bar item missing id".to_string());
            };
            if !ids.insert(id) {
                return Err("duplicate bar item id".to_string());
            }
        }
    }
    // Ensure widgets shape is valid.
    count_enabled_widgets(resolved.get("widgets").ok_or("missing widgets")?)?;

    let mut inherited = Vec::new();
    inherited_paths(&source, &resolved, "", &mut inherited);

    let mut result = match envelope("show", resolved) {
        Json::Object(map) => map,
        _ => unreachable!(),
    };
    result.insert("source".to_string(), source);
    result.insert("inherited_paths".to_string(), Json::Array(inherited));
    Ok(json::encode(&Json::Object(result)))
}
