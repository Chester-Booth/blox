use std::io::{self, BufRead, BufReader, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use crate::hardware;
use crate::hypr;
use crate::json::{self, Json};
use crate::system::{self, CpuSample};
use crate::workspaces::{self, DesktopResolver};

enum Event {
    StdinLine(String),
    StdinClosed,
    HyprEvent(String),
    HyprReconnected,
}

fn emit(domain: &str, data: Json) {
    let msg = Json::obj([
        ("domain", Json::String(domain.to_string())),
        ("data", data),
    ]);
    let mut out = json::encode(&msg);
    out.push('\n');
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(out.as_bytes());
    let _ = stdout.flush();
}

fn hypr_event_affects_workspaces(name: &str) -> bool {
    matches!(
        name,
        "workspace"
            | "workspacev2"
            | "createworkspace"
            | "createworkspacev2"
            | "destroyworkspace"
            | "destroyworkspacev2"
            | "moveworkspace"
            | "moveworkspacev2"
            | "renameworkspace"
            | "activespecial"
            | "activespecialv2"
            | "focusedmon"
            | "focusedmonv2"
            | "monitoradded"
            | "monitoraddedv2"
            | "monitorremoved"
            | "monitorremovedv2"
            | "openwindow"
            | "closewindow"
            | "movewindow"
            | "movewindowv2"
            | "activewindow"
            | "activewindowv2"
            | "windowtitle"
            | "windowtitlev2"
            | "fullscreen"
            | "urgent"
            | "pin"
            | "configreloaded"
    )
}

/// Persistent single-process bar telemetry & Hyprland event daemon.
/// Eliminates continuous bash/python subprocess forks from BarStatus.qml.
pub fn run() -> io::Result<()> {
    let (tx, rx) = mpsc::channel::<Event>();

    // Stdin reader thread: exits daemon cleanly on EOF.
    let tx_stdin = tx.clone();
    thread::Builder::new()
        .name("bar-stdin".to_string())
        .stack_size(128 * 1024)
        .spawn(move || {
            let stdin = io::stdin();
            let mut reader = BufReader::new(stdin.lock());
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => {
                        let _ = tx_stdin.send(Event::StdinClosed);
                        return;
                    }
                    Ok(_) => {
                        let trimmed = line.trim_end_matches(&['\r', '\n'][..]).to_string();
                        if tx_stdin.send(Event::StdinLine(trimmed)).is_err() {
                            return;
                        }
                    }
                }
            }
        })?;

    // Hyprland event socket reader thread with automatic reconnect.
    let tx_hypr = tx;
    thread::Builder::new()
        .name("bar-hypr".to_string())
        .stack_size(128 * 1024)
        .spawn(move || {
            let mut first = true;
            loop {
                match hypr::connect_events() {
                    Ok(stream) => {
                        if !first && tx_hypr.send(Event::HyprReconnected).is_err() {
                            return;
                        }
                        first = false;
                        let mut reader = BufReader::new(stream);
                        let mut line = String::new();
                        loop {
                            line.clear();
                            match reader.read_line(&mut line) {
                                Ok(0) | Err(_) => break,
                                Ok(_) => {
                                    if let Some((ev, _)) = line.trim_end().split_once(">>") {
                                        if tx_hypr.send(Event::HyprEvent(ev.to_string())).is_err() {
                                            return;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Err(_) => {
                        first = false;
                    }
                }
                thread::sleep(Duration::from_secs(2));
            }
        })?;

    let mut cpu = CpuSample::default();
    let mut resolver = DesktopResolver::new();
    let mut system_interval_ms: u64 = 0; // 0 = paused while performance popout closed
    let mut next_system_at: Option<Instant> = None;
    let mut pending_ws_flush: Option<Instant> = None;

    // Emit initial snapshots immediately on connect.
    emit("workspaces", workspaces::collect_status(&mut resolver));
    emit("system", system::collect(&mut cpu));
    emit("brightness", hardware::brightness_status("", false));
    emit("touchpad", hardware::touchpad_status());
    emit("nightLight", hardware::night_light_status());
    emit("caffeine", hardware::caffeine_status(false));

    loop {
        let now = Instant::now();
        let next_deadline = [next_system_at, pending_ws_flush]
            .into_iter()
            .flatten()
            .min();

        let event = match next_deadline {
            Some(deadline) => match rx.recv_timeout(deadline.saturating_duration_since(now)) {
                Ok(ev) => Some(ev),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => return Ok(()),
            },
            None => match rx.recv() {
                Ok(ev) => Some(ev),
                Err(_) => return Ok(()),
            },
        };

        if let Some(ev) = event {
            match ev {
                Event::StdinClosed => return Ok(()),
                Event::StdinLine(raw) => {
                    if let Some(msg) = json::parse(raw.as_bytes()) {
                        match msg.get_str("cmd").unwrap_or("") {
                            "refresh" => {
                                let domain = msg.get_str("domain").unwrap_or("all");
                                let dev = msg.get_str("device").unwrap_or("");
                                if domain == "all" || domain == "system" {
                                    emit("system", system::collect(&mut cpu));
                                }
                                if domain == "all" || domain == "workspaces" {
                                    emit("workspaces", workspaces::collect_status(&mut resolver));
                                }
                                if domain == "all" || domain == "brightness" {
                                    emit("brightness", hardware::brightness_status(dev, false));
                                }
                                if domain == "all" || domain == "touchpad" {
                                    emit("touchpad", hardware::touchpad_status());
                                }
                                if domain == "all" || domain == "nightLight" {
                                    emit("nightLight", hardware::night_light_status());
                                }
                                if domain == "all" || domain == "caffeine" {
                                    emit("caffeine", hardware::caffeine_status(true));
                                }
                            }
                            "set_system_interval" => {
                                let ms = msg.get_i64("ms").unwrap_or(0).max(0) as u64;
                                system_interval_ms = ms;
                                next_system_at = if ms > 0 {
                                    Some(Instant::now() + Duration::from_millis(ms))
                                } else {
                                    None
                                };
                            }
                            _ => {}
                        }
                    }
                }
                Event::HyprEvent(name) => {
                    if hypr_event_affects_workspaces(&name) && pending_ws_flush.is_none() {
                        pending_ws_flush = Some(Instant::now() + Duration::from_millis(20));
                    }
                    if matches!(
                        name.as_str(),
                        "monitoradded" | "monitoraddedv2" | "monitorremoved" | "monitorremovedv2"
                    ) {
                        emit("monitorEvent", Json::obj([("event", Json::String(name))]));
                    }
                }
                Event::HyprReconnected => {
                    emit("workspaces", workspaces::collect_status(&mut resolver));
                }
            }
        }

        let now = Instant::now();
        if let Some(due) = pending_ws_flush {
            if now >= due {
                pending_ws_flush = None;
                emit("workspaces", workspaces::collect_status(&mut resolver));
            }
        }
        if let Some(due) = next_system_at {
            if now >= due {
                emit("system", system::collect(&mut cpu));
                next_system_at = if system_interval_ms > 0 {
                    Some(now + Duration::from_millis(system_interval_ms))
                } else {
                    None
                };
            }
        }
    }
}
