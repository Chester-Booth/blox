"""Private, bounded clipboard storage used by the Blox launcher."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sqlite3
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

SCHEMA_VERSION = 1
MAX_PAYLOAD = 32 * 1024 * 1024
MAX_UNPINNED_BYTES = 500 * 1024 * 1024
FILE_ICON_EXTENSIONS = {
    **dict.fromkeys((".7z", ".apk", ".bz2", ".cab", ".cbr", ".cbz", ".deb", ".gz", ".iso", ".jar", ".lz", ".lz4", ".rar", ".rpm", ".tar", ".tbz", ".tbz2", ".tgz", ".txz", ".war", ".whl", ".xpi", ".xz", ".zip", ".zst"), "file-archive"),
    **dict.fromkeys((".aac", ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".wma"), "file-audio"),
    **dict.fromkeys((".c",), "file-c"),
    **dict.fromkeys((".cs",), "file-c-sharp"),
    **dict.fromkeys((".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"), "file-cpp"),
    **dict.fromkeys((".css",), "file-css"),
    **dict.fromkeys((".csv", ".tsv"), "file-csv"),
    **dict.fromkeys((".doc", ".docx", ".odt", ".rtf"), "file-doc"),
    **dict.fromkeys((".htm", ".html", ".xhtml"), "file-html"),
    **dict.fromkeys((".avif", ".bmp", ".gif", ".heic", ".ico", ".tif", ".tiff", ".webp"), "file-image"),
    **dict.fromkeys((".cfg", ".conf", ".ini"), "file-ini"),
    **dict.fromkeys((".jpeg", ".jpg"), "file-jpg"),
    **dict.fromkeys((".js", ".mjs"), "file-js"),
    **dict.fromkeys((".jsx",), "file-jsx"),
    **dict.fromkeys((".markdown", ".md", ".mdown"), "file-md"),
    **dict.fromkeys((".pdf",), "file-pdf"),
    **dict.fromkeys((".png",), "file-png"),
    **dict.fromkeys((".odp", ".ppt", ".pptx"), "file-ppt"),
    **dict.fromkeys((".py", ".pyw"), "file-py"),
    **dict.fromkeys((".rs",), "file-rs"),
    **dict.fromkeys((".sql",), "file-sql"),
    **dict.fromkeys((".svg",), "file-svg"),
    **dict.fromkeys((".log", ".rst", ".tex", ".text", ".txt"), "file-text"),
    **dict.fromkeys((".ts",), "file-ts"),
    **dict.fromkeys((".tsx",), "file-tsx"),
    **dict.fromkeys((".avi", ".m4v", ".mkv", ".mov", ".mp4", ".mpeg", ".mpg", ".webm"), "file-video"),
    **dict.fromkeys((".vue",), "file-vue"),
    **dict.fromkeys((".ods", ".xls", ".xlsx"), "file-xls"),
    **dict.fromkeys((".bash", ".fish", ".go", ".java", ".json", ".kt", ".kts", ".lua", ".php", ".qml", ".rb", ".sh", ".swift", ".toml", ".xml", ".yaml", ".yml", ".zsh"), "file-code"),
}
FILE_ICON_NAMES = {
    "dockerfile": "file-code",
    "justfile": "file-code",
    "makefile": "file-code",
}


def file_icon(path: Path) -> str:
    return FILE_ICON_NAMES.get(path.name.lower(), FILE_ICON_EXTENSIONS.get(path.suffix.lower(), "file"))


class Store:
    def __init__(self, root: Path):
        self.root = root
        self.payloads = root / "payloads"
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.payloads.mkdir(mode=0o700, exist_ok=True)
        root.chmod(0o700)
        self.payloads.chmod(0o700)
        self.db = sqlite3.connect(root / "history.sqlite3", timeout=5)
        self.db.row_factory = sqlite3.Row
        try:
            self.db.execute("PRAGMA busy_timeout=5000")
            self.db.execute("PRAGMA journal_mode=WAL")
            self._migrate()
        except Exception:
            self.db.close()
            raise
        for path in (root / "history.sqlite3", root / "history.sqlite3-wal", root / "history.sqlite3-shm"):
            if path.exists():
                path.chmod(0o600)

    def _migrate(self) -> None:
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version > SCHEMA_VERSION:
            raise RuntimeError(f"clipboard schema {version} is newer than supported schema {SCHEMA_VERSION}")
        if version == 0:
            self.db.executescript(
                """
                BEGIN IMMEDIATE;
                CREATE TABLE items(
                  id INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE,
                  mime TEXT NOT NULL, preview TEXT NOT NULL DEFAULT '',
                  payload_path TEXT NOT NULL, size INTEGER NOT NULL,
                  created_at INTEGER NOT NULL, last_used INTEGER NOT NULL,
                  use_count INTEGER NOT NULL DEFAULT 1, pinned_at INTEGER
                );
                CREATE VIRTUAL TABLE item_search USING fts5(preview, content='items', content_rowid='id');
                CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
                  INSERT INTO item_search(rowid, preview) VALUES (new.id, new.preview);
                END;
                CREATE TRIGGER items_ad AFTER DELETE ON items BEGIN
                  INSERT INTO item_search(item_search, rowid, preview) VALUES('delete', old.id, old.preview);
                END;
                CREATE TRIGGER items_au AFTER UPDATE OF preview ON items BEGIN
                  INSERT INTO item_search(item_search, rowid, preview) VALUES('delete', old.id, old.preview);
                  INSERT INTO item_search(rowid, preview) VALUES (new.id, new.preview);
                END;
                PRAGMA user_version=1;
                COMMIT;
                """
            )

    def ingest(self, mime: str, data: bytes, preview: str = "") -> int | None:
        if not data or len(data) > MAX_PAYLOAD:
            return None
        digest = hashlib.sha256(mime.encode() + b"\0" + data).hexdigest()
        now = time.time_ns()
        final = self.payloads / digest
        temporary = self.payloads / f".{digest}.{os.getpid()}.tmp"
        final_existed = final.exists()
        try:
            with temporary.open("xb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.chmod(0o600)
            os.replace(temporary, final)
            directory = os.open(self.payloads, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            self.db.execute("BEGIN IMMEDIATE")
            row = self.db.execute("SELECT id FROM items WHERE digest=?", (digest,)).fetchone()
            if row:
                self.db.execute(
                    "UPDATE items SET last_used=?, use_count=use_count+1 WHERE id=?",
                    (now, row["id"]),
                )
                item_id = row["id"]
            else:
                cursor = self.db.execute(
                    "INSERT INTO items(digest,mime,preview,payload_path,size,created_at,last_used)"
                    " VALUES(?,?,?,?,?,?,?)",
                    (digest, mime, preview[:4096], digest, len(data), now, now),
                )
                item_id = cursor.lastrowid
            trimmed = self._trim()
            self.db.commit()
            for payload in trimmed:
                (self.payloads / payload).unlink(missing_ok=True)
            return item_id
        except Exception:
            try:
                self.db.rollback()
            except sqlite3.Error:
                pass
            temporary.unlink(missing_ok=True)
            if not final_existed:
                final.unlink(missing_ok=True)
            raise

    def _trim(self) -> list[str]:
        removed: list[str] = []
        total = self.db.execute(
            "SELECT COALESCE(SUM(size),0) FROM items WHERE pinned_at IS NULL"
        ).fetchone()[0]
        while total > MAX_UNPINNED_BYTES:
            row = self.db.execute(
                "SELECT id,payload_path,size FROM items WHERE pinned_at IS NULL ORDER BY last_used LIMIT 1"
            ).fetchone()
            if not row:
                break
            self.db.execute("DELETE FROM items WHERE id=?", (row["id"],))
            removed.append(row["payload_path"])
            total -= row["size"]
        return removed

    @staticmethod
    def _cursor(row: sqlite3.Row) -> str:
        values = [1 if row["pinned_at"] is not None else 0, row["pinned_at"] or 0, row["last_used"], row["id"]]
        return base64.urlsafe_b64encode(json.dumps(values, separators=(",", ":")).encode()).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str) -> tuple[int, int, int, int]:
        try:
            padding = "=" * (-len(cursor) % 4)
            values = json.loads(base64.urlsafe_b64decode(cursor + padding))
        except Exception as error:
            raise ValueError("invalid clipboard cursor") from error
        if not isinstance(values, list) or len(values) != 4 or any(not isinstance(value, int) for value in values):
            raise ValueError("invalid clipboard cursor")
        pinned, pinned_at, last_used, item_id = values
        if pinned not in (0, 1) or min(pinned_at, last_used, item_id) < 0:
            raise ValueError("invalid clipboard cursor")
        return pinned, pinned_at, last_used, item_id

    def list(self, query: str = "", limit: int = 50, cursor: str | None = None) -> tuple[list[dict], str | None]:
        limit = max(1, min(limit, 100))
        args: list[object] = []
        where = []
        join = ""
        if query.strip():
            join = " JOIN item_search s ON s.rowid=i.id"
            terms = [term.replace('"', '""') for term in query.split() if term]
            where.append("s.preview MATCH ?")
            args.append(" AND ".join(f'"{term}"*' for term in terms))
        if cursor:
            pinned, pinned_at, last_used, item_id = self._decode_cursor(cursor)
            if pinned:
                where.append("((i.pinned_at IS NOT NULL AND (i.pinned_at,i.last_used,i.id) < (?,?,?)) OR i.pinned_at IS NULL)")
                args.extend((pinned_at, last_used, item_id))
            else:
                where.append("(i.pinned_at IS NULL AND (i.last_used,i.id) < (?,?))")
                args.extend((last_used, item_id))
        clause = " WHERE " + " AND ".join(where) if where else ""
        rows = self.db.execute(
            f"SELECT i.id,i.mime,i.preview,i.size,i.last_used,i.use_count,i.pinned_at"
            f" FROM items i{join}{clause} ORDER BY (i.pinned_at IS NOT NULL) DESC,"
            " i.pinned_at DESC,i.last_used DESC,i.id DESC LIMIT ?",
            (*args, limit + 1),
        ).fetchall()
        next_cursor = self._cursor(rows[limit - 1]) if len(rows) > limit else None
        items = [dict(row) for row in rows[:limit]]
        for item in items:
            item["file_path"] = ""
            item["file_size"] = 0
            item["file_icon"] = "file"
            if item["mime"].startswith("image/"):
                payload = self.item(item["id"])["payload_path"]
                item["payload_uri"] = (self.payloads / payload).as_uri()
            else:
                item["payload_uri"] = ""
            if item["mime"].split(";", 1)[0] == "text/uri-list":
                payload = self.item(item["id"])["payload_path"]
                lines = (self.payloads / payload).read_text(errors="replace").splitlines()
                uri = next((line.strip() for line in lines if line.strip() and not line.startswith("#")), "")
                parsed = urlparse(uri)
                if parsed.scheme == "file":
                    path = Path(unquote(parsed.path))
                    item["file_path"] = str(path)
                    item["file_icon"] = file_icon(path)
                    try:
                        item["file_size"] = path.stat().st_size
                    except OSError:
                        item["file_size"] = item["size"]
        return items, next_cursor

    def item(self, item_id: int) -> sqlite3.Row:
        row = self.db.execute("SELECT * FROM items WHERE id=?", (item_id,)).fetchone()
        if not row:
            raise KeyError(item_id)
        return row

    def pin(self, item_id: int, value: bool) -> None:
        self.db.execute("UPDATE items SET pinned_at=? WHERE id=?", (time.time_ns() if value else None, item_id))
        self.db.commit()

    def remove(self, item_id: int) -> None:
        row = self.item(item_id)
        self.db.execute("DELETE FROM items WHERE id=?", (item_id,))
        self.db.commit()
        (self.payloads / row["payload_path"]).unlink(missing_ok=True)

    def maintenance(self) -> int:
        known = {row[0] for row in self.db.execute("SELECT payload_path FROM items")}
        removed = 0
        for path in self.payloads.iterdir():
            if path.name not in known:
                path.unlink()
                removed += 1
        return removed

    def clear(self) -> int:
        rows = self.db.execute("SELECT payload_path FROM items").fetchall()
        self.db.execute("DELETE FROM items")
        self.db.commit()
        for row in rows:
            (self.payloads / row["payload_path"]).unlink(missing_ok=True)
        return len(rows)
