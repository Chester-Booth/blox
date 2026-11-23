use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use crate::hardware;
use crate::hypr;
use crate::json::{self, Json};
use crate::system::{self, CpuSample};
use crate::workspaces::{self, DesktopResolver};

const POLLIN: i16 = 0x0001;
const POLLERR: i16 = 0x0008;
const POLLHUP: i16 = 0x0010;

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

unsafe extern "C" {
    fn poll(fds: *mut PollFd, count: usize, timeout: i32) -> i32;
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
    let mut cpu = CpuSample::default();
    let mut resolver = DesktopResolver::new();
    let mut hypr_stream: Option<UnixStream> = hypr::connect_events().ok();
    let mut hypr_buf: Vec<u8> = Vec::new();
    let mut stdin_buf: Vec<u8> = Vec::new();
    let mut stdin = io::stdin();

    let mut system_interval_ms: u64 = 0; // 0 = paused while performance popout closed
    let mut next_system_at: Option<Instant> = None;
    let mut pending_ws_flush: Option<Instant> = None;
    let mut next_hypr_retry: Option<Instant> = if hypr_stream.is_none() {
        Some(Instant::now() + Duration::from_secs(2))
    } else {
        None
    };

    // Emit initial snapshots immediately on connect.
    emit("workspaces", workspaces::collect_status(&mut resolver));
    emit("system", system::collect(&mut cpu));
    emit("brightness", hardware::brightness_status("", false));
    emit("touchpad", hardware::touchpad_status());
    emit("nightLight", hardware::night_light_status());
    emit("caffeine", hardware::caffeine_status(false));

    let mut chunk = [0_u8; 32768];
    loop {
        let now = Instant::now();
        let mut timeout_ms: i32 = -1;
        for deadline in [next_system_at, pending_ws_flush, next_hypr_retry].into_iter().flatten() {
            let rem = deadline.saturating_duration_since(now).as_millis().min(i32::MAX as u128) as i32;
            timeout_ms = if timeout_ms < 0 { rem } else { timeout_ms.min(rem) };
        }

        let mut pollfds = Vec::with_capacity(2);
        pollfds.push(PollFd { fd: 0, events: POLLIN, revents: 0 });
        if let Some(ref s) = hypr_stream {
            pollfds.push(PollFd { fd: s.as_raw_fd(), events: POLLIN, revents: 0 });
        }

        let rc = unsafe { poll(pollfds.as_mut_ptr(), pollfds.len(), timeout_ms) };
        if rc < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }

        if pollfds[0].revents & (POLLIN | POLLHUP | POLLERR) != 0 {
            let n = stdin.read(&mut chunk)?;
            if n == 0 {
                return Ok(());
            }
            stdin_buf.extend_from_slice(&chunk[..n]);
            while let Some(nl) = stdin_buf.iter().position(|b| *b == b'\n') {
                let raw: Vec<u8> = stdin_buf.drain(..=nl).collect();
                let Some(msg) = json::parse(&raw[..raw.len() - 1]) else { continue };
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

        if pollfds.len() > 1 && pollfds[1].revents & (POLLIN | POLLHUP | POLLERR) != 0 {
            let mut disconnected = false;
            if let Some(ref mut stream) = hypr_stream {
                loop {
                    match stream.read(&mut chunk) {
                        Ok(0) => {
                            disconnected = true;
                            break;
                        }
                        Ok(n) => hypr_buf.extend_from_slice(&chunk[..n]),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(_) => {
                            disconnected = true;
                            break;
                        }
                    }
                }
            }
            while let Some(nl) = hypr_buf.iter().position(|b| *b == b'\n') {
                let raw: Vec<u8> = hypr_buf.drain(..=nl).collect();
                let line = String::from_utf8_lossy(&raw[..raw.len() - 1]);
                if let Some((ev, _)) = line.split_once(">>") {
                    if hypr_event_affects_workspaces(ev) && pending_ws_flush.is_none() {
                        // Coalesce bursty Hyprland events into one snapshot.
                        pending_ws_flush = Some(Instant::now() + Duration::from_millis(20));
                    }
                    if matches!(ev, "monitoradded" | "monitoraddedv2" | "monitorremoved" | "monitorremovedv2") {
                        emit("monitorEvent", Json::obj([("event", Json::String(ev.to_string()))]));
                    }
                }
            }
            if disconnected {
                hypr_stream = None;
                hypr_buf.clear();
                next_hypr_retry = Some(Instant::now() + Duration::from_secs(2));
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
        if let Some(due) = next_hypr_retry {
            if now >= due {
                if let Ok(s) = hypr::connect_events() {
                    hypr_stream = Some(s);
                    next_hypr_retry = None;
                    emit("workspaces", workspaces::collect_status(&mut resolver));
                } else {
                    next_hypr_retry = Some(now + Duration::from_secs(2));
                }
            }
        }
    }
}
