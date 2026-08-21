#!/usr/bin/env python3
"""JSON CLI for the launcher clipboard store."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
from io import BytesIO
from pathlib import Path
from urllib.parse import unquote, urlparse

from PIL import Image, UnidentifiedImageError

from clipboard_store import MAX_PAYLOAD, SCHEMA_VERSION, Store

MAX_IMAGE_PIXELS = 16_000_000


def reply(**values: object) -> None:
    print(json.dumps({"schema_version": SCHEMA_VERSION, "ok": True, "error": None, **values}))


def image_mime(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        mime = "image/png"
    elif data.startswith(b"\xff\xd8\xff"):
        mime = "image/jpeg"
    elif data.startswith((b"GIF87a", b"GIF89a")):
        mime = "image/gif"
    elif data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        mime = "image/webp"
    else:
        return None
    try:
        with Image.open(BytesIO(data)) as image:
            width, height = image.size
            if width <= 0 or height <= 0 or width * height > MAX_IMAGE_PIXELS:
                return None
            image.verify()
    except (Image.DecompressionBombError, OSError, UnidentifiedImageError, ValueError):
        return None
    return mime


def canonical_file_uris(mime: str, data: bytes) -> bytes | None:
    base_mime = mime.split(";", 1)[0].lower()
    if base_mime not in ("text/plain", "text/uri-list"):
        return None
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return None

    uris = []
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parsed = urlparse(line)
        if parsed.scheme != "file" or parsed.netloc not in ("", "localhost") or parsed.query or parsed.fragment:
            return None
        path = Path(unquote(parsed.path))
        if base_mime == "text/plain" and not path.exists():
            return None
        uris.append(path.as_uri())
    if not uris:
        return None
    return ("\r\n".join(uris) + "\r\n").encode()


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "blox-launcher/clipboard")
    sub = parser.add_subparsers(dest="command", required=True)
    ingest = sub.add_parser("ingest")
    ingest.add_argument("--mime", required=True)
    ingest.add_argument("--sensitive", action="store_true")
    listing = sub.add_parser("list")
    listing.add_argument("--query", default="")
    listing.add_argument("--limit", type=int, default=50)
    listing.add_argument("--cursor")
    for name in ("pin", "unpin", "remove", "replay"):
        command = sub.add_parser(name)
        command.add_argument("id", type=int)
    sub.add_parser("maintenance")
    sub.add_parser("clear")
    args = parser.parse_args()
    store = None
    lock = None
    try:
        # Payload files and their database rows form one store. Serialise every
        # operation so reads cannot race remove/clear and ingest cannot race a
        # deletion of the same digest.
        runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
        runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path = runtime / "blox-launcher-clipboard.lock"
        lock = lock_path.open("a+b")
        lock_path.chmod(0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        store = Store(args.root)
        if args.command == "ingest":
            if args.sensitive or os.environ.get("CLIPBOARD_STATE", "").lower() == "sensitive":
                reply(skipped="sensitive")
                return 0
            data = sys.stdin.buffer.read(MAX_PAYLOAD + 1)
            mime = args.mime
            file_uris = canonical_file_uris(mime, data)
            if file_uris is not None:
                mime = "text/uri-list"
                data = file_uris
            elif mime.startswith("image/"):
                mime = image_mime(data)
                if mime is None:
                    reply(id=None, skipped="unsupported-image")
                    return 0
            preview = data.decode("utf-8", "replace") if mime.startswith("text/") else f"{mime} · {len(data)} bytes"
            item_id = store.ingest(mime, data, preview)
            reply(id=item_id, skipped=None if item_id else "empty-or-too-large")
        elif args.command == "list":
            items, cursor = store.list(args.query, args.limit, args.cursor)
            reply(items=items, cursor=cursor)
        elif args.command in ("pin", "unpin"):
            store.pin(args.id, args.command == "pin")
            reply(id=args.id)
        elif args.command == "remove":
            store.remove(args.id)
            reply(id=args.id)
        elif args.command == "replay":
            row = store.item(args.id)
            data = (store.payloads / row["payload_path"]).read_bytes()
            completed = subprocess.run(["wl-copy", "--type", row["mime"]], input=data, check=False)
            if completed.returncode:
                raise RuntimeError("wl-copy failed")
            reply(id=args.id, mime=row["mime"])
        elif args.command == "maintenance":
            reply(removed=store.maintenance())
        else:
            reply(removed=store.clear())
        return 0
    except Exception as error:
        print(json.dumps({"schema_version": SCHEMA_VERSION, "ok": False, "items": [], "cursor": None, "error": str(error)}))
        return 1
    finally:
        if store is not None:
            store.db.close()
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
