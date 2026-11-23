use std::collections::HashMap;
use std::env;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::json::{self, Json};
use crate::sha256;

const SCHEMA_VERSION: i64 = 1;
const MAX_PAYLOAD: usize = 32 * 1024 * 1024;
const MAX_UNPINNED_BYTES: i64 = 500 * 1024 * 1024;
const MAX_IMAGE_PIXELS: u64 = 16_000_000;

const LOCK_EX: c_int = 2;
const O_CLOEXEC: c_int = 0x80000;
const POLLIN: i16 = 0x0001;
const POLLERR: i16 = 0x0008;
const POLLHUP: i16 = 0x0010;
const SOL_SOCKET: c_int = 1;
const SCM_RIGHTS: c_int = 1;
const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
const SQLITE_OPEN_CREATE: c_int = 0x00000004;

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

#[repr(C)]
struct IoVec {
    iov_base: *mut c_void,
    iov_len: usize,
}

#[repr(C)]
struct MsgHdr {
    msg_name: *mut c_void,
    msg_namelen: u32,
    msg_iov: *mut IoVec,
    msg_iovlen: usize,
    msg_control: *mut c_void,
    msg_controllen: usize,
    msg_flags: c_int,
}

#[repr(C)]
struct CMsgHdr {
    cmsg_len: usize,
    cmsg_level: c_int,
    cmsg_type: c_int,
}

#[repr(C)]
struct Sqlite3 {
    _private: [u8; 0],
}

#[repr(C)]
struct Sqlite3Stmt {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn flock(fd: c_int, operation: c_int) -> c_int;
    fn getuid() -> u32;
    fn pipe2(fds: *mut c_int, flags: c_int) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn poll(fds: *mut PollFd, count: usize, timeout: c_int) -> c_int;
    fn sendmsg(sockfd: c_int, msg: *const MsgHdr, flags: c_int) -> isize;
    fn umask(mask: u32) -> u32;
}

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(
        filename: *const c_char,
        pp_db: *mut *mut Sqlite3,
        flags: c_int,
        z_vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close(db: *mut Sqlite3) -> c_int;
    fn sqlite3_errmsg(db: *mut Sqlite3) -> *const c_char;
    fn sqlite3_exec(
        db: *mut Sqlite3,
        sql: *const c_char,
        callback: *const c_void,
        arg: *mut c_void,
        errmsg: *mut *mut c_char,
    ) -> c_int;
    fn sqlite3_free(ptr: *mut c_void);
    fn sqlite3_prepare_v2(
        db: *mut Sqlite3,
        z_sql: *const c_char,
        n_byte: c_int,
        pp_stmt: *mut *mut Sqlite3Stmt,
        pz_tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_bind_text(
        stmt: *mut Sqlite3Stmt,
        idx: c_int,
        val: *const c_char,
        n: c_int,
        destructor: isize,
    ) -> c_int;
    fn sqlite3_bind_int64(stmt: *mut Sqlite3Stmt, idx: c_int, val: i64) -> c_int;
    fn sqlite3_step(stmt: *mut Sqlite3Stmt) -> c_int;
    fn sqlite3_column_int64(stmt: *mut Sqlite3Stmt, col: c_int) -> i64;
    fn sqlite3_column_text(stmt: *mut Sqlite3Stmt, col: c_int) -> *const u8;
    fn sqlite3_column_bytes(stmt: *mut Sqlite3Stmt, col: c_int) -> c_int;
    fn sqlite3_last_insert_rowid(db: *mut Sqlite3) -> i64;
    fn sqlite3_finalize(stmt: *mut Sqlite3Stmt) -> c_int;
}

const SQLITE_TRANSIENT: isize = -1;

struct Db {
    raw: *mut Sqlite3,
}

impl Drop for Db {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe {
                sqlite3_close(self.raw);
            }
        }
    }
}

struct Stmt {
    raw: *mut Sqlite3Stmt,
}

impl Drop for Stmt {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe {
                sqlite3_finalize(self.raw);
            }
        }
    }
}

impl Db {
    fn open(path: &Path) -> Result<Self, String> {
        let c_path = CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| "invalid sqlite path".to_string())?;
        let mut raw: *mut Sqlite3 = ptr::null_mut();
        let rc = unsafe {
            sqlite3_open_v2(
                c_path.as_ptr(),
                &mut raw,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                ptr::null(),
            )
        };
        if rc != SQLITE_OK || raw.is_null() {
            let msg = if raw.is_null() {
                format!("sqlite open failed ({rc})")
            } else {
                let s = unsafe { CStr::from_ptr(sqlite3_errmsg(raw)) }
                    .to_string_lossy()
                    .into_owned();
                unsafe { sqlite3_close(raw) };
                s
            };
            return Err(msg);
        }
        Ok(Self { raw })
    }

    fn errmsg(&self) -> String {
        unsafe { CStr::from_ptr(sqlite3_errmsg(self.raw)) }
            .to_string_lossy()
            .into_owned()
    }

    fn exec(&self, sql: &str) -> Result<(), String> {
        let c_sql = CString::new(sql).map_err(|_| "sql contains NUL".to_string())?;
        let mut err: *mut c_char = ptr::null_mut();
        let rc = unsafe { sqlite3_exec(self.raw, c_sql.as_ptr(), ptr::null(), ptr::null_mut(), &mut err) };
        if rc != SQLITE_OK {
            let msg = if !err.is_null() {
                let s = unsafe { CStr::from_ptr(err) }.to_string_lossy().into_owned();
                unsafe { sqlite3_free(err as *mut c_void) };
                s
            } else {
                self.errmsg()
            };
            return Err(msg);
        }
        Ok(())
    }

    fn prepare(&self, sql: &str) -> Result<Stmt, String> {
        let mut raw: *mut Sqlite3Stmt = ptr::null_mut();
        let rc = unsafe {
            sqlite3_prepare_v2(
                self.raw,
                sql.as_ptr() as *const c_char,
                sql.len() as c_int,
                &mut raw,
                ptr::null_mut(),
            )
        };
        if rc != SQLITE_OK || raw.is_null() {
            return Err(self.errmsg());
        }
        Ok(Stmt { raw })
    }

    fn last_insert_rowid(&self) -> i64 {
        unsafe { sqlite3_last_insert_rowid(self.raw) }
    }
}

impl Stmt {
    fn bind_text(&self, idx: c_int, val: &str) -> Result<(), String> {
        let rc = unsafe {
            sqlite3_bind_text(
                self.raw,
                idx,
                val.as_ptr() as *const c_char,
                val.len() as c_int,
                SQLITE_TRANSIENT,
            )
        };
        if rc != SQLITE_OK {
            return Err(format!("sqlite bind_text failed ({rc})"));
        }
        Ok(())
    }

    fn bind_i64(&self, idx: c_int, val: i64) -> Result<(), String> {
        let rc = unsafe { sqlite3_bind_int64(self.raw, idx, val) };
        if rc != SQLITE_OK {
            return Err(format!("sqlite bind_int64 failed ({rc})"));
        }
        Ok(())
    }

    fn step(&self) -> c_int {
        unsafe { sqlite3_step(self.raw) }
    }

    fn col_i64(&self, col: c_int) -> i64 {
        unsafe { sqlite3_column_int64(self.raw, col) }
    }

    fn col_str(&self, col: c_int) -> String {
        let ptr = unsafe { sqlite3_column_text(self.raw, col) };
        let len = unsafe { sqlite3_column_bytes(self.raw, col) };
        if ptr.is_null() || len <= 0 {
            return String::new();
        }
        let slice = unsafe { std::slice::from_raw_parts(ptr, len as usize) };
        String::from_utf8_lossy(slice).into_owned()
    }
}

fn default_clipboard_root() -> PathBuf {
    let base = match env::var("XDG_DATA_HOME") {
        Ok(val) if !val.is_empty() => PathBuf::from(val),
        _ => PathBuf::from(env::var("HOME").unwrap_or_default()).join(".local/share"),
    };
    base.join("blox-launcher/clipboard")
}

fn runtime_dir() -> PathBuf {
    match env::var("XDG_RUNTIME_DIR") {
        Ok(val) if !val.is_empty() => PathBuf::from(val),
        _ => PathBuf::from(format!("/run/user/{}", unsafe { getuid() })),
    }
}

fn chmod_0600(path: &Path) {
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
}

fn chmod_0700(path: &Path) {
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
}

fn acquire_store_lock() -> Result<File, String> {
    let rt = runtime_dir();
    fs::create_dir_all(&rt).map_err(|e| format!("create runtime dir: {e}"))?;
    chmod_0700(&rt);
    let lock_path = rt.join("blox-launcher-clipboard.lock");
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(&lock_path)
        .map_err(|e| format!("open clipboard lock: {e}"))?;
    chmod_0600(&lock_path);
    if unsafe { flock(file.as_raw_fd(), LOCK_EX) } != 0 {
        return Err(format!("flock failed: {}", io::Error::last_os_error()));
    }
    Ok(file)
}

fn open_store(root: &Path) -> Result<(Db, PathBuf), String> {
    let payloads = root.join("payloads");
    fs::create_dir_all(&payloads).map_err(|e| format!("create clipboard dirs: {e}"))?;
    chmod_0700(root);
    chmod_0700(&payloads);
    let db_path = root.join("history.sqlite3");
    let db = Db::open(&db_path)?;
    db.exec("PRAGMA busy_timeout=5000")?;
    db.exec("PRAGMA journal_mode=WAL")?;

    let ver_stmt = db.prepare("PRAGMA user_version")?;
    let version = if ver_stmt.step() == SQLITE_ROW {
        ver_stmt.col_i64(0)
    } else {
        0
    };
    drop(ver_stmt);

    if version > SCHEMA_VERSION {
        return Err(format!(
            "clipboard schema {version} is newer than supported schema {SCHEMA_VERSION}"
        ));
    }
    if version == 0 {
        db.exec(
            "BEGIN IMMEDIATE;\
             CREATE TABLE items(\
               id INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE,\
               mime TEXT NOT NULL, preview TEXT NOT NULL DEFAULT '',\
               payload_path TEXT NOT NULL, size INTEGER NOT NULL,\
               created_at INTEGER NOT NULL, last_used INTEGER NOT NULL,\
               use_count INTEGER NOT NULL DEFAULT 1, pinned_at INTEGER\
             );\
             CREATE VIRTUAL TABLE item_search USING fts5(preview, content='items', content_rowid='id');\
             CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN \
               INSERT INTO item_search(rowid, preview) VALUES (new.id, new.preview); \
             END;\
             CREATE TRIGGER items_ad AFTER DELETE ON items BEGIN \
               INSERT INTO item_search(item_search, rowid, preview) VALUES('delete', old.id, old.preview); \
             END;\
             CREATE TRIGGER items_au AFTER UPDATE OF preview ON items BEGIN \
               INSERT INTO item_search(item_search, rowid, preview) VALUES('delete', old.id, old.preview); \
               INSERT INTO item_search(rowid, preview) VALUES (new.id, new.preview); \
             END;\
             PRAGMA user_version=1;\
             COMMIT;",
        )?;
    }

    for suffix in ["history.sqlite3", "history.sqlite3-wal", "history.sqlite3-shm"] {
        let p = root.join(suffix);
        if p.exists() {
            chmod_0600(&p);
        }
    }
    Ok((db, payloads))
}

fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hi = (bytes[i + 1] as char).to_digit(16)?;
            let lo = (bytes[i + 2] as char).to_digit(16)?;
            out.push(((hi << 4) | lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn percent_encode_file_uri(path: &str) -> String {
    let mut out = String::from("file://");
    for &b in path.as_bytes() {
        let safe = b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.' | b'~');
        if safe {
            out.push(b as char);
        } else {
            use std::fmt::Write;
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

fn canonical_file_uris(mime: &str, data: &[u8]) -> Option<Vec<u8>> {
    let base_mime = mime.split(';').next()?.trim().to_ascii_lowercase();
    if base_mime != "text/plain" && base_mime != "text/uri-list" {
        return None;
    }
    let text = std::str::from_utf8(data).ok()?;
    let mut uris = Vec::new();
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let rest = line.strip_prefix("file://")?;
        if rest.contains('?') || rest.contains('#') {
            return None;
        }
        let path_encoded = if rest.starts_with('/') {
            rest
        } else if let Some(after_local) = rest.strip_prefix("localhost/") {
            &rest[9..9 + 1 + after_local.len()]
        } else {
            return None;
        };
        let decoded = percent_decode(path_encoded)?;
        if !decoded.starts_with('/') {
            return None;
        }
        if base_mime == "text/plain" && !Path::new(&decoded).exists() {
            return None;
        }
        uris.push(percent_encode_file_uri(&decoded));
    }
    if uris.is_empty() {
        return None;
    }
    let mut joined = uris.join("\r\n");
    joined.push_str("\r\n");
    Some(joined.into_bytes())
}

fn valid_dims(w: u32, h: u32) -> bool {
    w > 0 && h > 0 && (w as u64).saturating_mul(h as u64) <= MAX_IMAGE_PIXELS
}

fn jpeg_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    let mut i = 2;
    while i + 3 < data.len() {
        if data[i] != 0xff {
            return None;
        }
        while i < data.len() && data[i] == 0xff {
            i += 1;
        }
        if i >= data.len() {
            return None;
        }
        let marker = data[i];
        i += 1;
        if marker == 0xd9 || marker == 0xda {
            break;
        }
        if matches!(marker, 0x01 | 0xd0..=0xd8) {
            continue;
        }
        if i + 2 > data.len() {
            return None;
        }
        let seg_len = u16::from_be_bytes([data[i], data[i + 1]]) as usize;
        if seg_len < 2 || i + seg_len > data.len() {
            return None;
        }
        let is_sof = matches!(
            marker,
            0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf
        );
        if is_sof && seg_len >= 7 {
            let h = u16::from_be_bytes([data[i + 3], data[i + 4]]) as u32;
            let w = u16::from_be_bytes([data[i + 5], data[i + 6]]) as u32;
            return Some((w, h));
        }
        i += seg_len;
    }
    None
}

fn webp_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 30 {
        return None;
    }
    match &data[12..16] {
        b"VP8X" => {
            let w = 1 + (data[24] as u32 | ((data[25] as u32) << 8) | ((data[26] as u32) << 16));
            let h = 1 + (data[27] as u32 | ((data[28] as u32) << 8) | ((data[29] as u32) << 16));
            Some((w, h))
        }
        b"VP8L" if data[20] == 0x2f => {
            let bits = u32::from_le_bytes([data[21], data[22], data[23], data[24]]);
            let w = (bits & 0x3fff) + 1;
            let h = ((bits >> 14) & 0x3fff) + 1;
            Some((w, h))
        }
        b"VP8 " if data[23..26] == [0x9d, 0x01, 0x2a] => {
            let w = (u16::from_le_bytes([data[26], data[27]]) & 0x3fff) as u32;
            let h = (u16::from_le_bytes([data[28], data[29]]) & 0x3fff) as u32;
            Some((w, h))
        }
        _ => None,
    }
}

/// Validate supported image magic bytes and bounded header dimensions without decoding pixels.
fn detect_image_mime(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        if data.len() < 24 || &data[12..16] != b"IHDR" {
            return None;
        }
        let w = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
        let h = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
        return valid_dims(w, h).then_some("image/png");
    }
    if data.starts_with(b"\xff\xd8\xff") {
        let (w, h) = jpeg_dimensions(data)?;
        return valid_dims(w, h).then_some("image/jpeg");
    }
    if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        if data.len() < 10 {
            return None;
        }
        let w = u16::from_le_bytes([data[6], data[7]]) as u32;
        let h = u16::from_le_bytes([data[8], data[9]]) as u32;
        return valid_dims(w, h).then_some("image/gif");
    }
    if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        let (w, h) = webp_dimensions(data)?;
        return valid_dims(w, h).then_some("image/webp");
    }
    None
}

fn now_ns() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

fn trim_unpinned(db: &Db) -> Result<Vec<String>, String> {
    let mut removed = Vec::new();
    let total_stmt = db.prepare("SELECT COALESCE(SUM(size),0) FROM items WHERE pinned_at IS NULL")?;
    let mut total = if total_stmt.step() == SQLITE_ROW {
        total_stmt.col_i64(0)
    } else {
        0
    };
    drop(total_stmt);

    while total > MAX_UNPINNED_BYTES {
        let sel = db.prepare(
            "SELECT id,payload_path,size FROM items WHERE pinned_at IS NULL ORDER BY last_used LIMIT 1",
        )?;
        if sel.step() != SQLITE_ROW {
            break;
        }
        let id = sel.col_i64(0);
        let payload_path = sel.col_str(1);
        let size = sel.col_i64(2);
        drop(sel);

        let del = db.prepare("DELETE FROM items WHERE id=?")?;
        del.bind_i64(1, id)?;
        if del.step() != SQLITE_DONE {
            return Err(db.errmsg());
        }
        removed.push(payload_path);
        total -= size;
    }
    Ok(removed)
}

#[derive(Debug)]
enum IngestOutcome {
    Stored(i64),
    Skipped(&'static str),
}

fn ingest_payload(root: &Path, raw_mime: &str, raw_data: &[u8], sensitive: bool) -> Result<IngestOutcome, String> {
    if sensitive {
        return Ok(IngestOutcome::Skipped("sensitive"));
    }
    if raw_data.is_empty() || raw_data.len() > MAX_PAYLOAD {
        return Ok(IngestOutcome::Skipped("empty-or-too-large"));
    }

    let (mime, owned_data): (String, Option<Vec<u8>>) =
        if let Some(uris) = canonical_file_uris(raw_mime, raw_data) {
            ("text/uri-list".to_string(), Some(uris))
        } else if raw_mime.starts_with("image/") {
            match detect_image_mime(raw_data) {
                Some(detected) => (detected.to_string(), None),
                None => return Ok(IngestOutcome::Skipped("unsupported-image")),
            }
        } else {
            (raw_mime.to_string(), None)
        };
    let data = owned_data.as_deref().unwrap_or(raw_data);
    if data.is_empty() || data.len() > MAX_PAYLOAD {
        return Ok(IngestOutcome::Skipped("empty-or-too-large"));
    }

    let preview: String = if mime.starts_with("text/") {
        String::from_utf8_lossy(data).chars().take(4096).collect()
    } else {
        format!("{mime} · {} bytes", data.len())
    };

    let _lock = acquire_store_lock()?;
    let (db, payloads) = open_store(root)?;
    let digest = sha256::hex_parts(&[mime.as_bytes(), b"\0", data]);
    let now = now_ns();
    let final_path = payloads.join(&digest);
    let temp_path = payloads.join(format!(".{digest}.{}.tmp", std::process::id()));
    let final_existed = final_path.exists();

    let write_res = (|| -> Result<i64, String> {
        {
            let mut f = OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&temp_path)
                .map_err(|e| format!("open temp payload: {e}"))?;
            f.write_all(data).map_err(|e| format!("write payload: {e}"))?;
            f.sync_all().map_err(|e| format!("fsync payload: {e}"))?;
        }
        chmod_0600(&temp_path);
        fs::rename(&temp_path, &final_path).map_err(|e| format!("rename payload: {e}"))?;
        if let Ok(dir) = File::open(&payloads) {
            let _ = dir.sync_all();
        }

        db.exec("BEGIN IMMEDIATE")?;
        let sel = db.prepare("SELECT id FROM items WHERE digest=?")?;
        sel.bind_text(1, &digest)?;
        let item_id = if sel.step() == SQLITE_ROW {
            let existing = sel.col_i64(0);
            drop(sel);
            let upd = db.prepare("UPDATE items SET last_used=?, use_count=use_count+1 WHERE id=?")?;
            upd.bind_i64(1, now)?;
            upd.bind_i64(2, existing)?;
            if upd.step() != SQLITE_DONE {
                return Err(db.errmsg());
            }
            existing
        } else {
            drop(sel);
            let ins = db.prepare(
                "INSERT INTO items(digest,mime,preview,payload_path,size,created_at,last_used) VALUES(?,?,?,?,?,?,?)",
            )?;
            ins.bind_text(1, &digest)?;
            ins.bind_text(2, &mime)?;
            ins.bind_text(3, &preview)?;
            ins.bind_text(4, &digest)?;
            ins.bind_i64(5, data.len() as i64)?;
            ins.bind_i64(6, now)?;
            ins.bind_i64(7, now)?;
            if ins.step() != SQLITE_DONE {
                return Err(db.errmsg());
            }
            db.last_insert_rowid()
        };

        let trimmed = trim_unpinned(&db)?;
        db.exec("COMMIT")?;
        for name in trimmed {
            let _ = fs::remove_file(payloads.join(name));
        }
        Ok(item_id)
    })();

    match write_res {
        Ok(id) => Ok(IngestOutcome::Stored(id)),
        Err(err) => {
            let _ = db.exec("ROLLBACK");
            let _ = fs::remove_file(&temp_path);
            if !final_existed {
                let _ = fs::remove_file(&final_path);
            }
            Err(err)
        }
    }
}

/// CLI entrypoint matching `clipboardctl.py ingest --mime <mime> [--root <dir>] [--sensitive]`.
pub fn cmd_ingest(args: &[String]) -> Result<(), String> {
    unsafe { umask(0o077) };
    let mut root = default_clipboard_root();
    let mut mime: Option<String> = None;
    let mut sensitive = env::var("CLIPBOARD_STATE")
        .map(|v| v.eq_ignore_ascii_case("sensitive"))
        .unwrap_or(false);

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--root" if i + 1 < args.len() => {
                root = PathBuf::from(&args[i + 1]);
                i += 2;
            }
            "--mime" if i + 1 < args.len() => {
                mime = Some(args[i + 1].clone());
                i += 2;
            }
            "--sensitive" => {
                sensitive = true;
                i += 1;
            }
            _ => i += 1,
        }
    }
    let mime = mime.ok_or("missing --mime")?;
    let mut buf = Vec::new();
    io::stdin()
        .take((MAX_PAYLOAD + 1) as u64)
        .read_to_end(&mut buf)
        .map_err(|e| format!("read stdin: {e}"))?;

    match ingest_payload(&root, &mime, &buf, sensitive) {
        Ok(IngestOutcome::Stored(id)) => {
            let msg = Json::obj([
                ("schema_version", Json::Int(SCHEMA_VERSION)),
                ("ok", Json::Bool(true)),
                ("error", Json::Null),
                ("id", Json::Int(id)),
                ("skipped", Json::Null),
            ]);
            println!("{}", json::encode(&msg));
            Ok(())
        }
        Ok(IngestOutcome::Skipped(reason)) => {
            let msg = Json::obj([
                ("schema_version", Json::Int(SCHEMA_VERSION)),
                ("ok", Json::Bool(true)),
                ("error", Json::Null),
                ("id", Json::Null),
                ("skipped", Json::String(reason.to_string())),
            ]);
            println!("{}", json::encode(&msg));
            Ok(())
        }
        Err(err) => {
            let msg = Json::obj([
                ("schema_version", Json::Int(SCHEMA_VERSION)),
                ("ok", Json::Bool(false)),
                ("items", Json::Array(Vec::new())),
                ("cursor", Json::Null),
                ("error", Json::String(err.clone())),
            ]);
            println!("{}", json::encode(&msg));
            Err(err)
        }
    }
}

// --- Minimal Wayland wire client for ext_data_control_v1 / zwlr_data_control_v1 ---

const WL_DISPLAY_ID: u32 = 1;
const WL_REGISTRY_ID: u32 = 2;
const WL_SYNC_CB_ID: u32 = 3;
const WL_SEAT_ID: u32 = 4;
const DATA_MGR_ID: u32 = 5;
const DATA_DEV_ID: u32 = 6;

fn push_u32(buf: &mut Vec<u8>, v: u32) {
    buf.extend_from_slice(&v.to_ne_bytes());
}

fn push_wl_str(buf: &mut Vec<u8>, s: &str) {
    let len = s.len() + 1;
    push_u32(buf, len as u32);
    buf.extend_from_slice(s.as_bytes());
    buf.push(0);
    while buf.len() % 4 != 0 {
        buf.push(0);
    }
}

fn build_wl_msg(obj_id: u32, opcode: u16, payload: &[u8]) -> Vec<u8> {
    let size = 8 + payload.len();
    let mut msg = Vec::with_capacity(size);
    push_u32(&mut msg, obj_id);
    push_u32(&mut msg, ((size as u32) << 16) | (opcode as u32));
    msg.extend_from_slice(payload);
    msg
}

fn read_u32(buf: &[u8], off: usize) -> Option<u32> {
    let slice = buf.get(off..off + 4)?;
    Some(u32::from_ne_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

fn read_wl_str(buf: &[u8], off: usize) -> Option<(String, usize)> {
    let len = read_u32(buf, off)? as usize;
    let start = off + 4;
    let end = start.checked_add(len)?;
    if end > buf.len() || len == 0 {
        return None;
    }
    let s = String::from_utf8_lossy(&buf[start..end - 1]).into_owned();
    let padded = (len + 3) & !3;
    Some((s, start + padded))
}

fn send_with_fd(sock_fd: RawFd, data: &[u8], attach_fd: RawFd) -> io::Result<()> {
    let mut iov = IoVec {
        iov_base: data.as_ptr() as *mut c_void,
        iov_len: data.len(),
    };
    const ALIGN: usize = std::mem::size_of::<usize>();
    const fn cmsg_align(len: usize) -> usize {
        (len + ALIGN - 1) & !(ALIGN - 1)
    }
    const HDR_LEN: usize = cmsg_align(std::mem::size_of::<CMsgHdr>());
    const DATA_LEN: usize = std::mem::size_of::<c_int>();
    const SPACE: usize = HDR_LEN + cmsg_align(DATA_LEN);

    let mut ctrl = [0_u64; SPACE.div_ceil(8)];
    let ctrl_ptr = ctrl.as_mut_ptr() as *mut u8;
    let cmsg = CMsgHdr {
        cmsg_len: HDR_LEN + DATA_LEN,
        cmsg_level: SOL_SOCKET,
        cmsg_type: SCM_RIGHTS,
    };
    let msg = MsgHdr {
        msg_name: ptr::null_mut(),
        msg_namelen: 0,
        msg_iov: &mut iov,
        msg_iovlen: 1,
        msg_control: ctrl_ptr as *mut c_void,
        msg_controllen: SPACE,
        msg_flags: 0,
    };
    let sent = unsafe {
        ptr::write_unaligned(ctrl_ptr as *mut CMsgHdr, cmsg);
        ptr::write_unaligned(ctrl_ptr.add(HDR_LEN) as *mut c_int, attach_fd);
        sendmsg(sock_fd, &msg, 0)
    };
    if sent < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn connect_wayland() -> io::Result<UnixStream> {
    let display = env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());
    let path = if display.starts_with('/') {
        PathBuf::from(display)
    } else {
        runtime_dir().join(display)
    };
    UnixStream::connect(path)
}

fn is_sensitive_mime(mime: &str) -> bool {
    let lower = mime.to_ascii_lowercase();
    lower == "x-kde-passwordmanagerhint" || lower == "application/x-password-manager"
}

fn choose_mime(mimes: &[String]) -> Option<(&str, &str)> {
    if mimes.iter().any(|m| is_sensitive_mime(m)) {
        return None;
    }
    for m in mimes {
        if m.eq_ignore_ascii_case("text/uri-list") {
            return Some((m.as_str(), "text/uri-list"));
        }
    }
    for preferred in ["image/png", "image/webp", "image/jpeg", "image/gif"] {
        if let Some(m) = mimes.iter().find(|m| m.eq_ignore_ascii_case(preferred)) {
            return Some((m.as_str(), preferred));
        }
    }
    for preferred in ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"] {
        if let Some(m) = mimes.iter().find(|m| m.as_str() == preferred) {
            return Some((m.as_str(), "text/plain;charset=utf-8"));
        }
    }
    if let Some(m) = mimes.iter().find(|m| m.starts_with("text/plain")) {
        return Some((m.as_str(), "text/plain;charset=utf-8"));
    }
    None
}

fn receive_offer_data(sock_fd: RawFd, offer_id: u32, request_mime: &str) -> Option<Vec<u8>> {
    let mut fds = [-1 as c_int; 2];
    if unsafe { pipe2(fds.as_mut_ptr(), O_CLOEXEC) } != 0 {
        return None;
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);

    let mut payload = Vec::with_capacity(request_mime.len() + 8);
    push_wl_str(&mut payload, request_mime);
    let msg = build_wl_msg(offer_id, 0, &payload);
    let send_ok = send_with_fd(sock_fd, &msg, write_fd).is_ok();
    unsafe { close(write_fd) };
    if !send_ok {
        unsafe { close(read_fd) };
        return None;
    }

    let mut reader = unsafe { File::from_raw_fd(read_fd) };
    let mut out = Vec::new();
    let mut chunk = [0_u8; 32768];
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        let rem = deadline
            .saturating_duration_since(std::time::Instant::now())
            .as_millis() as c_int;
        if rem <= 0 {
            break;
        }
        let mut pfd = PollFd {
            fd: reader.as_raw_fd(),
            events: POLLIN,
            revents: 0,
        };
        let rc = unsafe { poll(&mut pfd, 1, rem) };
        if rc <= 0 {
            if rc < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                let take = n.min((MAX_PAYLOAD + 1).saturating_sub(out.len()));
                out.extend_from_slice(&chunk[..take]);
                if out.len() > MAX_PAYLOAD {
                    return None;
                }
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        }
    }
    Some(out)
}

fn destroy_offer(stream: &mut UnixStream, offer_id: u32) {
    let msg = build_wl_msg(offer_id, 1, &[]);
    let _ = stream.write_all(&msg);
}

/// Persistent single-process Wayland clipboard watcher replacing 3x wl-paste + Python ingest forks.
pub fn cmd_watch(args: &[String]) -> Result<(), String> {
    unsafe { umask(0o077) };
    let mut root = default_clipboard_root();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--root" && i + 1 < args.len() {
            root = PathBuf::from(&args[i + 1]);
            i += 2;
        } else {
            i += 1;
        }
    }

    // Verify clipboard store opens cleanly before connecting to Wayland.
    {
        let _lock = acquire_store_lock()?;
        let _ = open_store(&root)?;
    }

    let mut stream = connect_wayland().map_err(|e| format!("wayland connect: {e}"))?;

    // 1. Request registry + sync roundtrip to discover wl_seat and data-control manager.
    let mut p = Vec::new();
    push_u32(&mut p, WL_REGISTRY_ID);
    stream
        .write_all(&build_wl_msg(WL_DISPLAY_ID, 1, &p))
        .map_err(|e| format!("wl_display.get_registry: {e}"))?;
    p.clear();
    push_u32(&mut p, WL_SYNC_CB_ID);
    stream
        .write_all(&build_wl_msg(WL_DISPLAY_ID, 0, &p))
        .map_err(|e| format!("wl_display.sync: {e}"))?;

    let mut seat_global: Option<u32> = None;
    let mut ext_mgr: Option<(u32, u32)> = None;
    let mut wlr_mgr: Option<(u32, u32)> = None;
    let mut synced = false;
    let mut wl_buf: Vec<u8> = Vec::with_capacity(8192);
    let mut tmp = [0_u8; 8192];

    while !synced {
        let n = stream.read(&mut tmp).map_err(|e| format!("wayland read: {e}"))?;
        if n == 0 {
            return Err("wayland closed during handshake".to_string());
        }
        wl_buf.extend_from_slice(&tmp[..n]);
        while wl_buf.len() >= 8 {
            let obj = read_u32(&wl_buf, 0).unwrap();
            let word = read_u32(&wl_buf, 4).unwrap();
            let size = (word >> 16) as usize;
            let opcode = (word & 0xffff) as u16;
            if size < 8 || wl_buf.len() < size {
                break;
            }
            if obj == WL_DISPLAY_ID && opcode == 0 {
                return Err("wayland display protocol error".to_string());
            } else if obj == WL_REGISTRY_ID && opcode == 0 {
                if let Some(name) = read_u32(&wl_buf, 8) {
                    if let Some((iface, next_off)) = read_wl_str(&wl_buf, 12) {
                        if let Some(version) = read_u32(&wl_buf, next_off) {
                            match iface.as_str() {
                                "wl_seat" if seat_global.is_none() => seat_global = Some(name),
                                "ext_data_control_manager_v1" => ext_mgr = Some((name, version.min(1))),
                                "zwlr_data_control_manager_v1" => wlr_mgr = Some((name, version.min(2))),
                                _ => {}
                            }
                        }
                    }
                }
            } else if obj == WL_SYNC_CB_ID && opcode == 0 {
                synced = true;
            }
            wl_buf.drain(..size);
        }
    }

    let seat_name = seat_global.ok_or("compositor exposes no wl_seat")?;
    let (mgr_iface, mgr_name, mgr_ver) = if let Some((name, ver)) = ext_mgr {
        ("ext_data_control_manager_v1", name, ver)
    } else if let Some((name, ver)) = wlr_mgr {
        ("zwlr_data_control_manager_v1", name, ver)
    } else {
        return Err("compositor exposes neither ext_data_control_manager_v1 nor zwlr_data_control_manager_v1".to_string());
    };

    // 2. Bind wl_seat (id 4) + data_control_manager (id 5) + get_data_device (id 6).
    p.clear();
    push_u32(&mut p, seat_name);
    push_wl_str(&mut p, "wl_seat");
    push_u32(&mut p, 1);
    push_u32(&mut p, WL_SEAT_ID);
    stream
        .write_all(&build_wl_msg(WL_REGISTRY_ID, 0, &p))
        .map_err(|e| format!("bind wl_seat: {e}"))?;

    p.clear();
    push_u32(&mut p, mgr_name);
    push_wl_str(&mut p, mgr_iface);
    push_u32(&mut p, mgr_ver);
    push_u32(&mut p, DATA_MGR_ID);
    stream
        .write_all(&build_wl_msg(WL_REGISTRY_ID, 0, &p))
        .map_err(|e| format!("bind data control manager: {e}"))?;

    p.clear();
    push_u32(&mut p, DATA_DEV_ID);
    push_u32(&mut p, WL_SEAT_ID);
    stream
        .write_all(&build_wl_msg(DATA_MGR_ID, 1, &p))
        .map_err(|e| format!("get_data_device: {e}"))?;

    // Signal readiness to ClipboardWatcher.qml.
    println!("{{\"ok\":true,\"ready\":true}}");
    let _ = io::stdout().flush();

    let mut offers: HashMap<u32, Vec<String>> = HashMap::new();
    let mut initial_selection_skipped = false;
    let stdin_fd = io::stdin().as_raw_fd();
    let wl_fd = stream.as_raw_fd();

    loop {
        let mut pollfds = [
            PollFd { fd: wl_fd, events: POLLIN, revents: 0 },
            PollFd { fd: stdin_fd, events: POLLIN, revents: 0 },
        ];
        let rc = unsafe { poll(pollfds.as_mut_ptr(), pollfds.len(), -1) };
        if rc < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!("poll: {err}"));
        }

        if pollfds[1].revents & (POLLHUP | POLLERR) != 0 {
            return Ok(());
        }
        if pollfds[1].revents & POLLIN != 0 {
            let mut drain = [0_u8; 64];
            match io::stdin().read(&mut drain) {
                Ok(0) => return Ok(()),
                _ => {}
            }
        }

        if pollfds[0].revents & (POLLIN | POLLHUP | POLLERR) != 0 {
            let n = stream.read(&mut tmp).map_err(|e| format!("wayland read: {e}"))?;
            if n == 0 {
                return Err("wayland display disconnected".to_string());
            }
            wl_buf.extend_from_slice(&tmp[..n]);
            while wl_buf.len() >= 8 {
                let obj = read_u32(&wl_buf, 0).unwrap();
                let word = read_u32(&wl_buf, 4).unwrap();
                let size = (word >> 16) as usize;
                let opcode = (word & 0xffff) as u16;
                if size < 8 || wl_buf.len() < size {
                    break;
                }

                if obj == WL_DISPLAY_ID && opcode == 0 {
                    return Err("wayland display protocol error".to_string());
                } else if obj == DATA_DEV_ID {
                    match opcode {
                        0 => {
                            if let Some(offer_id) = read_u32(&wl_buf, 8) {
                                offers.insert(offer_id, Vec::new());
                            }
                        }
                        1 => {
                            let offer_id = read_u32(&wl_buf, 8).unwrap_or(0);
                            if offer_id != 0 {
                                let mimes = offers.remove(&offer_id).unwrap_or_default();
                                // Skip the initial selection snapshot emitted on bind only if empty,
                                // or ingest every change (deduped by digest in SQLite).
                                if initial_selection_skipped {
                                    if let Some((req_mime, store_mime)) = choose_mime(&mimes) {
                                        if let Some(data) = receive_offer_data(wl_fd, offer_id, req_mime) {
                                            let _ = ingest_payload(&root, store_mime, &data, false);
                                        }
                                    }
                                } else {
                                    initial_selection_skipped = true;
                                }
                                destroy_offer(&mut stream, offer_id);
                            } else {
                                initial_selection_skipped = true;
                            }
                        }
                        2 => return Ok(()),
                        3 => {
                            // Ignore primary selection, but destroy its offer so server IDs never leak.
                            let offer_id = read_u32(&wl_buf, 8).unwrap_or(0);
                            if offer_id != 0 {
                                offers.remove(&offer_id);
                                destroy_offer(&mut stream, offer_id);
                            }
                        }
                        _ => {}
                    }
                } else if opcode == 0 && offers.contains_key(&obj) {
                    if let Some((mime, _)) = read_wl_str(&wl_buf, 8) {
                        if let Some(list) = offers.get_mut(&obj) {
                            list.push(mime);
                        }
                    }
                }

                wl_buf.drain(..size);
            }
        }
    }
}
