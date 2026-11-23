use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

use crate::json::{self, Json};

const MAX_REQUEST: usize = 1024 * 1024;
const MAX_ITEMS: usize = 10_000;
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

fn valid_options(value: &Json) -> Option<Vec<String>> {
    let data = value.as_object()?;
    if !matches!(data.get("version"), Some(Json::Int(1))) {
        return None;
    }
    let options = match data.get("options") {
        Some(Json::Array(options)) if options.len() <= MAX_ITEMS => options,
        _ => return None,
    };
    options
        .iter()
        .map(|option| option.as_str().map(str::to_string))
        .collect()
}

fn parse_request(value: &[u8]) -> Option<Json> {
    let mut message = json::parse(value)?;
    valid_options(&message)?;
    if let Json::Object(data) = &mut message {
        data.insert("event".to_string(), Json::String("request".to_string()));
    }
    Some(message)
}

fn parse_update(value: &[u8]) -> Option<Json> {
    let message = json::parse(value)?;
    let data = message.as_object()?;
    if !matches!(data.get("version"), Some(Json::Int(1)))
        || data.get("event").and_then(Json::as_str) != Some("options")
    {
        return None;
    }
    let options = valid_options(&message)?;
    Some(Json::Object(BTreeMap::from([
        ("event".to_string(), Json::String("update".to_string())),
        ("options".to_string(), Json::Array(options.into_iter().map(Json::String).collect())),
    ])))
}

fn parse_response(value: &[u8]) -> Option<Json> {
    let message = json::parse(value)?;
    let data = message.as_object()?;
    let cancelled = matches!(data.get("cancelled"), Some(Json::Bool(true)));
    let selected = match data.get("value") {
        Some(Json::String(v)) => v.clone(),
        None => String::new(),
        _ => return None,
    };
    Some(Json::Object(BTreeMap::from([
        ("version".to_string(), Json::Int(1)),
        ("ok".to_string(), Json::Bool(!cancelled)),
        ("value".to_string(), Json::String(selected)),
    ])))
}

struct Client {
    stream: UnixStream,
    buffer: Vec<u8>,
}

fn send(client: &mut Client, value: Json) {
    let mut encoded = json::encode(&value).into_bytes();
    encoded.push(b'\n');
    let _ = client.stream.write_all(&encoded);
}

fn error_response(error: &str) -> Json {
    Json::obj([
        ("version", Json::Int(1)),
        ("ok", Json::Bool(false)),
        ("error", Json::String(error.to_string())),
    ])
}

fn remove_client(clients: &mut Vec<Client>, active: &mut Option<usize>, index: usize, announce: bool) {
    let was_active = *active == Some(index);
    clients.remove(index);
    if let Some(current) = *active {
        if current == index {
            *active = None;
        } else if current > index {
            *active = Some(current - 1);
        }
    }
    if was_active && announce {
        println!("{{\"event\":\"abandoned\"}}");
        let _ = io::stdout().flush();
    }
}

fn runtime_path() -> Option<(PathBuf, PathBuf)> {
    let root = PathBuf::from(env::var_os("XDG_RUNTIME_DIR")?);
    let directory = root.join("blox-launcher");
    Some((directory.clone(), directory.join("dmenu.sock")))
}

/// Serve the launcher dmenu Unix socket bridge over stdin/stdout JSONL.
pub fn run() -> io::Result<()> {
    let (runtime, socket_path) = runtime_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
    fs::create_dir_all(&runtime)?;
    fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700))?;
    let _ = fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path)?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;

    let mut stdin = io::stdin();
    let mut stdin_buffer = Vec::new();
    let mut clients: Vec<Client> = Vec::new();
    let mut active: Option<usize> = None;

    'server: loop {
        let mut pollfds = vec![
            PollFd { fd: listener.as_raw_fd(), events: POLLIN, revents: 0 },
            PollFd { fd: 0, events: POLLIN, revents: 0 },
        ];
        pollfds.extend(clients.iter().map(|c| PollFd {
            fd: c.stream.as_raw_fd(),
            events: POLLIN,
            revents: 0,
        }));
        let result = unsafe { poll(pollfds.as_mut_ptr(), pollfds.len(), -1) };
        if result < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }

        if pollfds[1].revents & (POLLIN | POLLHUP) != 0 {
            let mut chunk = [0_u8; 8192];
            let size = stdin.read(&mut chunk)?;
            if size == 0 {
                break 'server;
            }
            stdin_buffer.extend_from_slice(&chunk[..size]);
            while let Some(end) = stdin_buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = stdin_buffer.drain(..=end).collect();
                if let Some(index) = active {
                    if let Some(value) = parse_response(&line[..line.len() - 1]) {
                        send(&mut clients[index], value);
                    } else {
                        send(&mut clients[index], error_response("invalid response"));
                    }
                    remove_client(&mut clients, &mut active, index, false);
                }
            }
        }

        if pollfds[0].revents & (POLLIN | POLLERR) != 0 {
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(true)?;
                        if active.is_some() {
                            let mut client = Client { stream, buffer: Vec::new() };
                            send(&mut client, error_response("busy"));
                        } else {
                            clients.push(Client { stream, buffer: Vec::new() });
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) => return Err(error),
                }
            }
        }

        let ready: Vec<usize> = pollfds
            .iter()
            .enumerate()
            .skip(2)
            .filter(|(_, entry)| entry.revents & (POLLIN | POLLERR | POLLHUP) != 0)
            .map(|(index, _)| index - 2)
            .collect();
        for index in ready.into_iter().rev() {
            if index >= clients.len() {
                continue;
            }
            let mut closed = false;
            let mut chunk = [0_u8; 65536];
            loop {
                match clients[index].stream.read(&mut chunk) {
                    Ok(0) => {
                        closed = true;
                        break;
                    }
                    Ok(size) => {
                        clients[index].buffer.extend_from_slice(&chunk[..size]);
                        if clients[index].buffer.len() > MAX_REQUEST {
                            closed = true;
                            break;
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(_) => {
                        closed = true;
                        break;
                    }
                }
            }
            if closed {
                let announce = active == Some(index);
                remove_client(&mut clients, &mut active, index, announce);
                continue;
            }
            while let Some(end) = clients[index].buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = clients[index].buffer.drain(..=end).collect();
                let payload = &line[..line.len() - 1];
                if active == Some(index) {
                    if let Some(value) = parse_update(payload) {
                        println!("{}", json::encode(&value));
                        let _ = io::stdout().flush();
                    } else {
                        send(&mut clients[index], error_response("invalid update"));
                        remove_client(&mut clients, &mut active, index, true);
                        break;
                    }
                } else if active.is_some() {
                    send(&mut clients[index], error_response("busy"));
                    remove_client(&mut clients, &mut active, index, false);
                    break;
                } else if let Some(value) = parse_request(payload) {
                    active = Some(index);
                    println!("{}", json::encode(&value));
                    let _ = io::stdout().flush();
                } else {
                    send(&mut clients[index], error_response("invalid request"));
                    remove_client(&mut clients, &mut active, index, false);
                    break;
                }
            }
        }
    }

    drop(clients);
    drop(listener);
    let _ = fs::remove_file(socket_path);
    Ok(())
}
