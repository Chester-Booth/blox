use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

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

#[derive(Clone, Debug, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Number(i64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

struct Parser<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> Parser<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, position: 0 }
    }

    fn parse(mut self) -> Option<Json> {
        let value = self.value()?;
        self.space();
        (self.position == self.bytes.len()).then_some(value)
    }

    fn space(&mut self) {
        while self.position < self.bytes.len() && self.bytes[self.position].is_ascii_whitespace() {
            self.position += 1;
        }
    }

    fn value(&mut self) -> Option<Json> {
        self.space();
        let byte = *self.bytes.get(self.position)?;
        match byte {
            b'n' if self.take(b"null") => Some(Json::Null),
            b't' if self.take(b"true") => Some(Json::Bool(true)),
            b'f' if self.take(b"false") => Some(Json::Bool(false)),
            b'"' => self.string().map(Json::String),
            b'[' => self.array(),
            b'{' => self.object(),
            b'-' | b'0'..=b'9' => self.number().map(Json::Number),
            _ => None,
        }
    }

    fn take(&mut self, expected: &[u8]) -> bool {
        if self.bytes.get(self.position..self.position + expected.len()) == Some(expected) {
            self.position += expected.len();
            true
        } else {
            false
        }
    }

    fn string(&mut self) -> Option<String> {
        if self.bytes.get(self.position) != Some(&b'"') {
            return None;
        }
        self.position += 1;
        let mut output = String::new();
        while self.position < self.bytes.len() {
            let byte = self.bytes[self.position];
            self.position += 1;
            match byte {
                b'"' => return Some(output),
                b'\\' => {
                    let escaped = *self.bytes.get(self.position)?;
                    self.position += 1;
                    match escaped {
                        b'"' => output.push('"'),
                        b'\\' => output.push('\\'),
                        b'/' => output.push('/'),
                        b'b' => output.push('\u{0008}'),
                        b'f' => output.push('\u{000c}'),
                        b'n' => output.push('\n'),
                        b'r' => output.push('\r'),
                        b't' => output.push('\t'),
                        b'u' => {
                            let end = self.position.checked_add(4)?;
                            let hex = std::str::from_utf8(self.bytes.get(self.position..end)?).ok()?;
                            let code = u32::from_str_radix(hex, 16).ok()?;
                            output.push(char::from_u32(code)?);
                            self.position = end;
                        }
                        _ => return None,
                    }
                }
                0..=0x1f => return None,
                byte if byte >= 0x80 => {
                    let start = self.position - 1;
                    while self.position < self.bytes.len() {
                        let next = self.bytes[self.position];
                        if next < 0x80 && (next == b'"' || next == b'\\' || next < 0x20) {
                            break;
                        }
                        self.position += 1;
                    }
                    output.push_str(std::str::from_utf8(self.bytes.get(start..self.position)?).ok()?);
                }
                _ => output.push(byte as char),
            }
        }
        None
    }

    fn array(&mut self) -> Option<Json> {
        self.position += 1;
        let mut values = Vec::new();
        self.space();
        if self.bytes.get(self.position) == Some(&b']') {
            self.position += 1;
            return Some(Json::Array(values));
        }
        loop {
            values.push(self.value()?);
            self.space();
            match self.bytes.get(self.position) {
                Some(b',') => self.position += 1,
                Some(b']') => {
                    self.position += 1;
                    return Some(Json::Array(values));
                }
                _ => return None,
            }
        }
    }

    fn object(&mut self) -> Option<Json> {
        self.position += 1;
        let mut values = BTreeMap::new();
        self.space();
        if self.bytes.get(self.position) == Some(&b'}') {
            self.position += 1;
            return Some(Json::Object(values));
        }
        loop {
            self.space();
            let key = self.string()?;
            self.space();
            if self.bytes.get(self.position) != Some(&b':') {
                return None;
            }
            self.position += 1;
            values.insert(key, self.value()?);
            self.space();
            match self.bytes.get(self.position) {
                Some(b',') => self.position += 1,
                Some(b'}') => {
                    self.position += 1;
                    return Some(Json::Object(values));
                }
                _ => return None,
            }
        }
    }

    fn number(&mut self) -> Option<i64> {
        let start = self.position;
        if self.bytes.get(self.position) == Some(&b'-') {
            self.position += 1;
        }
        while self.position < self.bytes.len() && self.bytes[self.position].is_ascii_digit() {
            self.position += 1;
        }
        std::str::from_utf8(self.bytes.get(start..self.position)?).ok()?.parse().ok()
    }
}

fn json_escape(value: &str) -> String {
    let mut output = String::with_capacity(value.len() + 2);
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character.is_control() => output.push_str(&format!("\\u{:04x}", character as u32)),
            character => output.push(character),
        }
    }
    output.push('"');
    output
}

fn encode(value: &Json) -> String {
    match value {
        Json::Null => "null".to_string(),
        Json::Bool(value) => value.to_string(),
        Json::Number(value) => value.to_string(),
        Json::String(value) => json_escape(value),
        Json::Array(values) => format!("[{}]", values.iter().map(encode).collect::<Vec<_>>().join(",")),
        Json::Object(values) => format!(
            "{{{}}}",
            values
                .iter()
                .map(|(key, value)| format!("{}:{}", json_escape(key), encode(value)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

fn object(value: &Json) -> Option<&BTreeMap<String, Json>> {
    if let Json::Object(value) = value { Some(value) } else { None }
}

fn valid_options(value: &Json) -> Option<Vec<String>> {
    let data = object(value)?;
    if !matches!(data.get("version"), Some(Json::Number(1))) {
        return None;
    }
    let options = match data.get("options") {
        Some(Json::Array(options)) if options.len() <= MAX_ITEMS => options,
        _ => return None,
    };
    options
        .iter()
        .map(|option| match option { Json::String(value) => Some(value.clone()), _ => None })
        .collect()
}

fn request(value: &[u8]) -> Option<Json> {
    let mut message = Parser::new(value).parse()?;
    valid_options(&message)?;
    if let Json::Object(data) = &mut message {
        data.insert("event".to_string(), Json::String("request".to_string()));
    }
    Some(message)
}

fn update(value: &[u8]) -> Option<Json> {
    let message = Parser::new(value).parse()?;
    let data = object(&message)?;
    if !matches!(data.get("version"), Some(Json::Number(1))) || data.get("event") != Some(&Json::String("options".to_string())) {
        return None;
    }
    let options = valid_options(&message)?;
    Some(Json::Object(BTreeMap::from([
        ("event".to_string(), Json::String("update".to_string())),
        ("options".to_string(), Json::Array(options.into_iter().map(Json::String).collect())),
    ])))
}

fn response(value: &[u8]) -> Option<Json> {
    let message = Parser::new(value).parse()?;
    let data = object(&message)?;
    let cancelled = matches!(data.get("cancelled"), Some(Json::Bool(true)));
    let selected = match data.get("value") {
        Some(Json::String(value)) => value.clone(),
        None => String::new(),
        _ => return None,
    };
    Some(Json::Object(BTreeMap::from([
        ("version".to_string(), Json::Number(1)),
        ("ok".to_string(), Json::Bool(!cancelled)),
        ("value".to_string(), Json::String(selected)),
    ])))
}

struct Client {
    stream: UnixStream,
    buffer: Vec<u8>,
}

fn send(client: &mut Client, value: Json) {
    let mut encoded = encode(&value).into_bytes();
    encoded.push(b'\n');
    let _ = client.stream.write_all(&encoded);
}

fn error_response(error: &str) -> Json {
    Json::Object(BTreeMap::from([
        ("version".to_string(), Json::Number(1)),
        ("ok".to_string(), Json::Bool(false)),
        ("error".to_string(), Json::String(error.to_string())),
    ]))
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

fn main() -> io::Result<()> {
    let (runtime, socket_path) = runtime_path().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is not set"))?;
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
        pollfds.extend(clients.iter().map(|client| PollFd { fd: client.stream.as_raw_fd(), events: POLLIN, revents: 0 }));
        let result = unsafe { poll(pollfds.as_mut_ptr(), pollfds.len(), -1) };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }

        if pollfds[1].revents & (POLLIN | POLLHUP) != 0 {
            let mut chunk = [0_u8; 8192];
            let size = stdin.read(&mut chunk)?;
            if size == 0 {
                break 'server;
            }
            stdin_buffer.extend_from_slice(&chunk[..size]);
            while let Some(end) = stdin_buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = stdin_buffer.drain(..=end).collect();
                if let Some(index) = active {
                    if let Some(value) = response(&line[..line.len() - 1]) {
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
            while let Some(end) = clients[index].buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = clients[index].buffer.drain(..=end).collect();
                let payload = &line[..line.len() - 1];
                if active == Some(index) {
                    if let Some(value) = update(payload) {
                        println!("{}", encode(&value));
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
                } else if let Some(value) = request(payload) {
                    active = Some(index);
                    println!("{}", encode(&value));
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
