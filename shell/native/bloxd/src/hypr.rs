use std::env;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use crate::json::{self, Json};

/// Direct Hyprland Unix socket IPC without spawning hyprctl subprocesses.
pub fn socket_path(name: &str) -> Option<PathBuf> {
    let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let runtime = env::var("XDG_RUNTIME_DIR").ok()?;
    if sig.is_empty() || runtime.is_empty() {
        return None;
    }
    Some(PathBuf::from(runtime).join("hypr").join(sig).join(name))
}

pub fn is_available() -> bool {
    socket_path(".socket.sock").map(|p| p.exists()).unwrap_or(false)
}

pub fn request(command: &str) -> io::Result<Vec<u8>> {
    let path = socket_path(".socket.sock")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Hyprland socket unavailable"))?;
    let mut stream = UnixStream::connect(path)?;
    stream.set_read_timeout(Some(Duration::from_millis(1500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(1500)))?;
    stream.write_all(command.as_bytes())?;
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let mut out = Vec::with_capacity(4096);
    stream.read_to_end(&mut out)?;
    Ok(out)
}

pub fn query_json(command: &str) -> Option<Json> {
    let bytes = request(command).ok()?;
    json::parse(&bytes)
}

pub fn connect_events() -> io::Result<UnixStream> {
    let path = socket_path(".socket2.sock")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Hyprland event socket unavailable"))?;
    let stream = UnixStream::connect(path)?;
    stream.set_nonblocking(true)?;
    Ok(stream)
}
