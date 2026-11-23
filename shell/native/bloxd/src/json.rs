use std::collections::BTreeMap;

/// Lightweight JSON DOM shared by all bloxd modules without external crates.
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

impl Json {
    pub fn obj(entries: impl IntoIterator<Item = (&'static str, Json)>) -> Json {
        let mut map = BTreeMap::new();
        for (k, v) in entries {
            map.insert(k.to_string(), v);
        }
        Json::Object(map)
    }

    pub fn as_object(&self) -> Option<&BTreeMap<String, Json>> {
        if let Json::Object(map) = self { Some(map) } else { None }
    }

    pub fn as_array(&self) -> Option<&Vec<Json>> {
        if let Json::Array(items) = self { Some(items) } else { None }
    }

    pub fn as_str(&self) -> Option<&str> {
        if let Json::String(s) = self { Some(s.as_str()) } else { None }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Int(v) => Some(*v),
            Json::Float(v) => Some(*v as i64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        if let Json::Bool(b) = self { Some(*b) } else { None }
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        self.as_object()?.get(key)
    }

    pub fn get_str(&self, key: &str) -> Option<&str> {
        self.get(key)?.as_str()
    }

    pub fn get_i64(&self, key: &str) -> Option<i64> {
        self.get(key)?.as_i64()
    }

    pub fn get_bool(&self, key: &str) -> Option<bool> {
        self.get(key)?.as_bool()
    }
}

pub fn parse(bytes: &[u8]) -> Option<Json> {
    Parser { bytes, pos: 0 }.parse()
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn parse(mut self) -> Option<Json> {
        let value = self.value()?;
        self.space();
        (self.pos == self.bytes.len()).then_some(value)
    }

    fn space(&mut self) {
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
    }

    fn value(&mut self) -> Option<Json> {
        self.space();
        match *self.bytes.get(self.pos)? {
            b'n' if self.take(b"null") => Some(Json::Null),
            b't' if self.take(b"true") => Some(Json::Bool(true)),
            b'f' if self.take(b"false") => Some(Json::Bool(false)),
            b'"' => self.string().map(Json::String),
            b'[' => self.array(),
            b'{' => self.object(),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn take(&mut self, expected: &[u8]) -> bool {
        if self.bytes.get(self.pos..self.pos + expected.len()) == Some(expected) {
            self.pos += expected.len();
            true
        } else {
            false
        }
    }

    fn string(&mut self) -> Option<String> {
        if self.bytes.get(self.pos) != Some(&b'"') {
            return None;
        }
        self.pos += 1;
        let mut out = String::new();
        while self.pos < self.bytes.len() {
            let byte = self.bytes[self.pos];
            self.pos += 1;
            match byte {
                b'"' => return Some(out),
                b'\\' => {
                    let esc = *self.bytes.get(self.pos)?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let code = self.hex4()?;
                            if (0xD800..=0xDBFF).contains(&code) {
                                if !self.take(b"\\u") {
                                    return None;
                                }
                                let low = self.hex4()?;
                                if !(0xDC00..=0xDFFF).contains(&low) {
                                    return None;
                                }
                                let combined = 0x10000 + (((code - 0xD800) << 10) | (low - 0xDC00));
                                out.push(char::from_u32(combined)?);
                            } else {
                                out.push(char::from_u32(code)?);
                            }
                        }
                        _ => return None,
                    }
                }
                0..=0x1f => return None,
                b if b >= 0x80 => {
                    let start = self.pos - 1;
                    while self.pos < self.bytes.len() {
                        let next = self.bytes[self.pos];
                        if next < 0x80 && (next == b'"' || next == b'\\' || next < 0x20) {
                            break;
                        }
                        self.pos += 1;
                    }
                    out.push_str(std::str::from_utf8(self.bytes.get(start..self.pos)?).ok()?);
                }
                b => out.push(b as char),
            }
        }
        None
    }

    fn hex4(&mut self) -> Option<u32> {
        let end = self.pos.checked_add(4)?;
        let hex = std::str::from_utf8(self.bytes.get(self.pos..end)?).ok()?;
        let code = u32::from_str_radix(hex, 16).ok()?;
        self.pos = end;
        Some(code)
    }

    fn array(&mut self) -> Option<Json> {
        self.pos += 1;
        let mut items = Vec::new();
        self.space();
        if self.bytes.get(self.pos) == Some(&b']') {
            self.pos += 1;
            return Some(Json::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.space();
            match self.bytes.get(self.pos) {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Some(Json::Array(items));
                }
                _ => return None,
            }
        }
    }

    fn object(&mut self) -> Option<Json> {
        self.pos += 1;
        let mut map = BTreeMap::new();
        self.space();
        if self.bytes.get(self.pos) == Some(&b'}') {
            self.pos += 1;
            return Some(Json::Object(map));
        }
        loop {
            self.space();
            let key = self.string()?;
            self.space();
            if self.bytes.get(self.pos) != Some(&b':') {
                return None;
            }
            self.pos += 1;
            map.insert(key, self.value()?);
            self.space();
            match self.bytes.get(self.pos) {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Some(Json::Object(map));
                }
                _ => return None,
            }
        }
    }

    fn number(&mut self) -> Option<Json> {
        let start = self.pos;
        let mut is_float = false;
        if self.bytes.get(self.pos) == Some(&b'-') {
            self.pos += 1;
        }
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_digit() {
            self.pos += 1;
        }
        if self.bytes.get(self.pos) == Some(&b'.') {
            is_float = true;
            self.pos += 1;
            while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_digit() {
                self.pos += 1;
            }
        }
        if matches!(self.bytes.get(self.pos), Some(b'e' | b'E')) {
            is_float = true;
            self.pos += 1;
            if matches!(self.bytes.get(self.pos), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_digit() {
                self.pos += 1;
            }
        }
        let raw = std::str::from_utf8(self.bytes.get(start..self.pos)?).ok()?;
        if is_float {
            let val: f64 = raw.parse().ok()?;
            val.is_finite().then_some(Json::Float(val))
        } else {
            raw.parse::<i64>().ok().map(Json::Int)
        }
    }
}

pub fn escape_string(value: &str, out: &mut String) {
    out.push('"');
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {
                use std::fmt::Write;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn encode_into(value: &Json, out: &mut String) {
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Int(n) => out.push_str(&n.to_string()),
        Json::Float(n) => {
            if n.is_finite() {
                out.push_str(&n.to_string());
            } else {
                out.push_str("null");
            }
        }
        Json::String(s) => escape_string(s, out),
        Json::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                encode_into(item, out);
            }
            out.push(']');
        }
        Json::Object(map) => {
            out.push('{');
            for (i, (k, v)) in map.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                escape_string(k, out);
                out.push(':');
                encode_into(v, out);
            }
            out.push('}');
        }
    }
}

pub fn encode(value: &Json) -> String {
    let mut out = String::with_capacity(256);
    encode_into(value, &mut out);
    out
}

pub fn capability(
    available: bool,
    ready: bool,
    can_change: bool,
    permission: &str,
    reason: Option<&str>,
) -> Json {
    Json::obj([
        ("available", Json::Bool(available)),
        ("ready", Json::Bool(ready)),
        ("canChange", Json::Bool(can_change)),
        ("permission", Json::String(permission.to_string())),
        ("reason", match reason {
            Some(r) if !r.is_empty() => Json::String(r.to_string()),
            _ => Json::Null,
        }),
    ])
}
