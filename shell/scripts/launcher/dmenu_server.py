#!/usr/bin/env python3
"""Bounded dmenu socket bridge for Quickshell."""

from __future__ import annotations

import json
import os
import selectors
import socket
import sys
from pathlib import Path

MAX_REQUEST = 1024 * 1024
MAX_ITEMS = 10_000


def send(client: socket.socket, value: dict) -> None:
    try:
        client.sendall(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    except OSError:
        pass


def forward_updates(buffer: bytearray) -> bool:
    while b"\n" in buffer:
        raw, _, remainder = buffer.partition(b"\n")
        buffer[:] = remainder
        try:
            message = json.loads(raw)
            options = message.get("options", [])
            if message.get("version") != 1 or message.get("event") != "options" or not isinstance(options, list) or len(options) > MAX_ITEMS or any(not isinstance(option, str) for option in options):
                return False
        except (TypeError, ValueError):
            return False
        print(json.dumps({"event": "update", "options": options}, separators=(",", ":")), flush=True)
    return True


def main() -> int:
    os.umask(0o077)
    runtime = Path(os.environ["XDG_RUNTIME_DIR"]) / "blox-launcher"
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = runtime / "dmenu.sock"
    path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    path.chmod(0o600)
    server.listen(4)
    server.setblocking(False)
    selector = selectors.DefaultSelector()
    selector.register(server, selectors.EVENT_READ, "server")
    selector.register(sys.stdin.buffer, selectors.EVENT_READ, "stdin")
    active: socket.socket | None = None
    buffers: dict[socket.socket, bytearray] = {}
    try:
        while True:
            for key, _ in selector.select():
                if key.data == "server":
                    client, _ = server.accept()
                    client.setblocking(False)
                    if active is not None:
                        send(client, {"version": 1, "ok": False, "error": "busy"})
                        client.close()
                    else:
                        buffers[client] = bytearray()
                        selector.register(client, selectors.EVENT_READ, "client")
                elif key.data == "stdin":
                    line = sys.stdin.buffer.readline()
                    if not line:
                        return 0
                    if active is not None:
                        try:
                            response = json.loads(line)
                            send(active, {
                                "version": 1,
                                "ok": not bool(response.get("cancelled")),
                                "value": str(response.get("value", "")),
                            })
                        except (TypeError, ValueError):
                            send(active, {"version": 1, "ok": False, "error": "invalid response"})
                        selector.unregister(active)
                        buffers.pop(active, None)
                        active.close()
                        active = None
                else:
                    client = key.fileobj
                    try:
                        chunk = client.recv(65536)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        selector.unregister(client)
                        client.close()
                        buffers.pop(client, None)
                        if active is client:
                            active = None
                            print('{"event":"abandoned"}', flush=True)
                        continue
                    buffer = buffers[client]
                    buffer.extend(chunk)
                    if len(buffer) > MAX_REQUEST or (b"\n" in buffer and buffer.index(b"\n") > MAX_REQUEST):
                        selector.unregister(client)
                        client.close()
                        buffers.pop(client, None)
                        if active is client:
                            active = None
                            print('{"event":"abandoned"}', flush=True)
                        continue
                    if client is active:
                        if not forward_updates(buffer):
                            send(client, {"version": 1, "ok": False, "error": "invalid update"})
                            selector.unregister(client)
                            client.close()
                            buffers.pop(client, None)
                            active = None
                            print('{"event":"abandoned"}', flush=True)
                        continue
                    if b"\n" not in buffer:
                        continue
                    raw, _, remainder = bytes(buffer).partition(b"\n")
                    try:
                        message = json.loads(raw)
                        options = message.get("options", [])
                        if message.get("version") != 1 or not isinstance(options, list) or len(options) > MAX_ITEMS or any(not isinstance(option, str) for option in options):
                            raise ValueError
                    except (TypeError, ValueError):
                        send(client, {"version": 1, "ok": False, "error": "invalid request"})
                        selector.unregister(client)
                        client.close()
                        buffers.pop(client, None)
                        continue
                    if active is not None:
                        send(client, {"version": 1, "ok": False, "error": "busy"})
                        selector.unregister(client)
                        client.close()
                        buffers.pop(client, None)
                        continue
                    buffers[client] = bytearray(remainder)
                    active = client
                    print(json.dumps({"event": "request", **message}, separators=(",", ":")), flush=True)
                    if not forward_updates(buffers[client]):
                        send(client, {"version": 1, "ok": False, "error": "invalid update"})
                        selector.unregister(client)
                        client.close()
                        buffers.pop(client, None)
                        active = None
                        print('{"event":"abandoned"}', flush=True)
    finally:
        for client in list(buffers):
            client.close()
        if active is not None:
            active.close()
        server.close()
        path.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
