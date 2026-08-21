#!/usr/bin/env python3
"""Black-box parity suite for the dmenu socket workers."""

from __future__ import annotations

import argparse
import json
import os
import select
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MAX_REQUEST = 1024 * 1024


def wait_for_socket(path: Path) -> None:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.005)
    raise AssertionError(f"worker did not create {path}")


def read_line(stream, timeout: float = 2.0) -> dict:
    ready, _, _ = select.select([stream], [], [], timeout)
    if not ready:
        raise AssertionError("worker produced no protocol line")
    line = stream.readline()
    if not line:
        raise AssertionError("worker exited before producing a protocol line")
    return json.loads(line)


def read_socket_line(client: socket.socket, timeout: float = 2.0) -> dict:
    client.settimeout(timeout)
    payload = bytearray()
    while b"\n" not in payload:
        chunk = client.recv(4096)
        if not chunk:
            raise AssertionError("worker closed the client socket")
        payload.extend(chunk)
    return json.loads(bytes(payload).split(b"\n", 1)[0])


class Worker:
    def __init__(self, command: list[str], test: unittest.TestCase):
        self.command = command
        self.test = test
        self.temporary = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temporary.name)
        self.socket_path = self.runtime / "blox-launcher/dmenu.sock"
        self.process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        environment = {**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)}
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        wait_for_socket(self.socket_path)
        self.test.assertEqual(0o700, stat.S_IMODE(self.socket_path.parent.stat().st_mode))
        self.test.assertEqual(0o600, stat.S_IMODE(self.socket_path.stat().st_mode))

    def connect(self) -> socket.socket:
        client = socket.socket(socket.AF_UNIX)
        client.connect(str(self.socket_path))
        return client

    def stdin(self, value: dict) -> None:
        assert self.process and self.process.stdin
        self.process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def stop(self) -> None:
        if not self.process:
            return
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)
        self.test.assertFalse(self.socket_path.exists())
        self.temporary.cleanup()


class ProtocolTests(unittest.TestCase):
    command: list[str]

    def setUp(self) -> None:
        self.worker = Worker(self.command, self)
        self.worker.start()

    def tearDown(self) -> None:
        self.worker.stop()

    def request(self, options: list[str] | None = None) -> tuple[socket.socket, dict]:
        client = self.worker.connect()
        request = {
            "version": 1,
            "options": ["one", "two"] if options is None else options,
            "prompt": "Pick",
            "query": "",
            "insensitive": True,
            "lines": 7,
            "monitor": "1",
            "bottom": True,
            "fast": False,
        }
        client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        message = read_line(self.worker.process.stdout)
        return client, message

    def test_request_response_and_permissions(self) -> None:
        client, message = self.request()
        self.assertEqual("request", message["event"])
        self.assertEqual(["one", "two"], message["options"])
        self.assertEqual("Pick", message["prompt"])
        self.assertTrue(message["insensitive"])
        self.worker.stdin({"value": "two", "cancelled": False})
        self.assertEqual({"version": 1, "ok": True, "value": "two"}, read_socket_line(client))
        client.close()

    def test_fast_updates_and_cancel(self) -> None:
        client, message = self.request([])
        self.assertEqual([], message["options"])
        client.sendall(json.dumps({"version": 1, "event": "options", "options": ["new", "list"]}, separators=(",", ":")).encode() + b"\n")
        self.assertEqual({"event": "update", "options": ["new", "list"]}, read_line(self.worker.process.stdout))
        self.worker.stdin({"value": "", "cancelled": True})
        self.assertEqual({"version": 1, "ok": False, "value": ""}, read_socket_line(client))
        client.close()

    def test_thousand_and_ten_thousand_item_requests(self) -> None:
        client, message = self.request(["item"] * 10_000)
        self.assertEqual(10_000, len(message["options"]))
        self.worker.stdin({"value": "item", "cancelled": False})
        read_socket_line(client)
        client.close()

        invalid = self.worker.connect()
        invalid.sendall(json.dumps({"version": 1, "options": ["item"] * 10_001}, separators=(",", ":")).encode() + b"\n")
        self.assertEqual("invalid request", read_socket_line(invalid)["error"])
        invalid.close()

    def test_busy_client_and_invalid_request(self) -> None:
        active, _ = self.request()
        busy = self.worker.connect()
        busy.sendall(b'{"version":1,"options":[]}\n')
        self.assertEqual("busy", read_socket_line(busy)["error"])
        busy.close()
        self.worker.stdin({"value": "one", "cancelled": False})
        read_socket_line(active)
        active.close()

        invalid = self.worker.connect()
        invalid.sendall(b"not json\n")
        self.assertEqual("invalid request", read_socket_line(invalid)["error"])
        invalid.close()

    def test_invalid_update_and_abandoned_client(self) -> None:
        invalid, _ = self.request()
        invalid.sendall(b'{"version":1,"event":"wrong","options":[]}\n')
        self.assertEqual("invalid update", read_socket_line(invalid)["error"])
        self.assertEqual({"event": "abandoned"}, read_line(self.worker.process.stdout))
        invalid.close()

        abandoned, _ = self.request()
        abandoned.close()
        self.assertEqual({"event": "abandoned"}, read_line(self.worker.process.stdout))

    def test_unterminated_request_limit_closes_only_the_client(self) -> None:
        client = self.worker.connect()
        client.sendall(b"x" * (MAX_REQUEST + 1))
        client.settimeout(2)
        self.assertEqual(b"", client.recv(1))
        self.assertIsNone(self.worker.process.poll())
        client.close()


def run_suite(name: str, command: list[str]) -> bool:
    test_case = type(f"{name.title()}ProtocolTests", (ProtocolTests,), {"command": command})
    suite = unittest.TestLoader().loadTestsFromTestCase(test_case)
    return unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--rust", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    args = parser.parse_args()
    commands = {
        "python": [sys.executable, str(args.python)],
        "rust": [str(args.rust)],
        "cpp": [str(args.cpp)],
    }
    return 0 if all(run_suite(name, command) for name, command in commands.items()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
