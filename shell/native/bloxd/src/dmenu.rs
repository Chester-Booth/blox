use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

use crate::json::{self, Json};

const MAX_REQUEST: usize = 1024 * 1024;
const MAX_ITEMS: usize = 10_000;

enum Event {
    StdinLine(Vec<u8>),
    StdinClosed,
    Accepted(UnixStream),
    ClientLine(u64, Vec<u8>),
    ClientClosed(u64),
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

fn send_json(stream: &mut UnixStream, value: Json) {
    let mut encoded = json::encode(&value).into_bytes();
    encoded.push(b'\n');
    let _ = stream.write_all(&encoded);
}

fn error_response(error: &str) -> Json {
    Json::obj([
        ("version", Json::Int(1)),
        ("ok", Json::Bool(false)),
        ("error", Json::String(error.to_string())),
    ])
}

fn runtime_path() -> Option<(PathBuf, PathBuf)> {
    let root = PathBuf::from(env::var_os("XDG_RUNTIME_DIR")?);
    let directory = root.join("blox-launcher");
    Some((directory.clone(), directory.join("dmenu.sock")))
}

fn spawn_client_reader(id: u64, mut stream: UnixStream, tx: mpsc::Sender<Event>) {
    let _ = thread::Builder::new()
        .name("dmenu-client".to_string())
        .stack_size(128 * 1024)
        .spawn(move || {
            let mut buffer = Vec::new();
            let mut chunk = vec![0_u8; 65536];
            loop {
                match stream.read(&mut chunk) {
                    Ok(0) | Err(_) => {
                        let _ = tx.send(Event::ClientClosed(id));
                        return;
                    }
                    Ok(size) => {
                        buffer.extend_from_slice(&chunk[..size]);
                        if buffer.len() > MAX_REQUEST {
                            let _ = tx.send(Event::ClientClosed(id));
                            return;
                        }
                        while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                            let line: Vec<u8> = buffer.drain(..=end).collect();
                            let payload = line[..line.len() - 1].to_vec();
                            if tx.send(Event::ClientLine(id, payload)).is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        });
}

fn close_client(
    clients: &mut HashMap<u64, UnixStream>,
    active: &mut Option<u64>,
    id: u64,
    announce: bool,
) {
    let was_active = *active == Some(id);
    if let Some(stream) = clients.remove(&id) {
        let _ = stream.shutdown(Shutdown::Both);
    }
    if was_active {
        *active = None;
        if announce {
            println!("{{\"event\":\"abandoned\"}}");
            let _ = io::stdout().flush();
        }
    }
}

/// Serve the launcher dmenu Unix socket bridge over stdin/stdout JSONL (zero unsafe).
pub fn run() -> io::Result<()> {
    let (runtime, socket_path) = runtime_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
    fs::create_dir_all(&runtime)?;
    fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700))?;
    let _ = fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path)?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))?;

    let (tx, rx) = mpsc::channel::<Event>();

    let tx_stdin = tx.clone();
    thread::Builder::new()
        .name("dmenu-stdin".to_string())
        .stack_size(128 * 1024)
        .spawn(move || {
            let stdin = io::stdin();
            let mut reader = BufReader::new(stdin.lock());
            let mut line = Vec::new();
            loop {
                line.clear();
                match reader.read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => {
                        let _ = tx_stdin.send(Event::StdinClosed);
                        return;
                    }
                    Ok(_) => {
                        if line.last() == Some(&b'\n') {
                            line.pop();
                        }
                        if tx_stdin.send(Event::StdinLine(line.clone())).is_err() {
                            return;
                        }
                    }
                }
            }
        })?;

    let tx_accept = tx.clone();
    let listener_clone = listener.try_clone()?;
    thread::Builder::new()
        .name("dmenu-accept".to_string())
        .stack_size(128 * 1024)
        .spawn(move || {
            for incoming in listener_clone.incoming() {
                match incoming {
                    Ok(stream) => {
                        if tx_accept.send(Event::Accepted(stream)).is_err() {
                            return;
                        }
                    }
                    Err(_) => return,
                }
            }
        })?;

    let mut next_id: u64 = 1;
    let mut clients: HashMap<u64, UnixStream> = HashMap::new();
    let mut active: Option<u64> = None;

    while let Ok(event) = rx.recv() {
        match event {
            Event::StdinClosed => break,
            Event::StdinLine(line) => {
                if let Some(id) = active {
                    if let Some(stream) = clients.get_mut(&id) {
                        if let Some(value) = parse_response(&line) {
                            send_json(stream, value);
                        } else {
                            send_json(stream, error_response("invalid response"));
                        }
                    }
                    close_client(&mut clients, &mut active, id, false);
                }
            }
            Event::Accepted(mut stream) => {
                if active.is_some() {
                    send_json(&mut stream, error_response("busy"));
                    let _ = stream.shutdown(Shutdown::Both);
                } else if let Ok(reader_stream) = stream.try_clone() {
                    let id = next_id;
                    next_id += 1;
                    clients.insert(id, stream);
                    spawn_client_reader(id, reader_stream, tx.clone());
                }
            }
            Event::ClientClosed(id) => {
                let announce = active == Some(id);
                close_client(&mut clients, &mut active, id, announce);
            }
            Event::ClientLine(id, payload) => {
                if !clients.contains_key(&id) {
                    continue;
                }
                if active == Some(id) {
                    if let Some(value) = parse_update(&payload) {
                        println!("{}", json::encode(&value));
                        let _ = io::stdout().flush();
                    } else {
                        if let Some(stream) = clients.get_mut(&id) {
                            send_json(stream, error_response("invalid update"));
                        }
                        close_client(&mut clients, &mut active, id, true);
                    }
                } else if active.is_some() {
                    if let Some(stream) = clients.get_mut(&id) {
                        send_json(stream, error_response("busy"));
                    }
                    close_client(&mut clients, &mut active, id, false);
                } else if let Some(value) = parse_request(&payload) {
                    active = Some(id);
                    println!("{}", json::encode(&value));
                    let _ = io::stdout().flush();
                } else {
                    if let Some(stream) = clients.get_mut(&id) {
                        send_json(stream, error_response("invalid request"));
                    }
                    close_client(&mut clients, &mut active, id, false);
                }
            }
        }
    }

    drop(clients);
    drop(listener);
    let _ = fs::remove_file(socket_path);
    Ok(())
}
