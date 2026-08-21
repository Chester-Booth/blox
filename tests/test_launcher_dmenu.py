import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


CLIENT = Path(__file__).parents[1] / "bin/dmenu"
SERVER = Path(__file__).parents[1] / "shell/scripts/launcher/dmenu_server.py"


class DmenuClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temp.name)
        self.socket_path = self.runtime / "blox-launcher/dmenu.sock"
        self.socket_path.parent.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def serve_once(self, response, request_count=1):
        ready = threading.Event()
        received = []

        def serve():
            server = socket.socket(socket.AF_UNIX)
            self.socket_path.unlink(missing_ok=True)
            server.bind(str(self.socket_path))
            server.listen(1)
            ready.set()
            client, _ = server.accept()
            with client:
                payload = b""
                while len(received) < request_count:
                    payload += client.recv(4096)
                    while b"\n" in payload and len(received) < request_count:
                        line, payload = payload.split(b"\n", 1)
                        received.append(json.loads(line))
                if response is not None:
                    client.sendall(response if isinstance(response, bytes) else json.dumps(response).encode() + b"\n")
            server.close()

        thread = threading.Thread(target=serve)
        thread.start()
        ready.wait(1)
        return thread, received

    def run_client(self, *arguments, input=b"one\ntwo\n"):
        return subprocess.run(
            [CLIENT, *arguments],
            input=input,
            capture_output=True,
            env={**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)},
            check=False,
        )

    def test_selection_preserves_exact_text_and_request_options(self):
        thread, received = self.serve_once({"version": 1, "ok": True, "value": "two"})
        result = self.run_client("-i", "-p", "Pick one", "-l", "7", "-m", "1", "-b")
        thread.join(1)
        self.assertEqual(0, result.returncode)
        self.assertEqual(b"two\n", result.stdout)
        self.assertEqual(["one", "two"], received[0]["options"])
        self.assertEqual("Pick one", received[0]["prompt"])
        self.assertTrue(received[0]["insensitive"])
        self.assertEqual(7, received[0]["lines"])
        self.assertEqual("1", received[0]["monitor"])
        self.assertTrue(received[0]["bottom"])
        self.assertFalse(received[0]["fast"])

    def test_fast_mode_requests_focus_before_sending_options(self):
        ready = threading.Event()
        received = []

        def serve():
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(self.socket_path))
            server.listen(1)
            ready.set()
            client, _ = server.accept()
            with client:
                payload = b""
                while len(received) < 2:
                    payload += client.recv(4096)
                    while b"\n" in payload and len(received) < 2:
                        line, payload = payload.split(b"\n", 1)
                        received.append(json.loads(line))
                client.sendall(b'{"version":1,"ok":true,"value":"two"}\n')
            server.close()

        thread = threading.Thread(target=serve)
        thread.start()
        ready.wait(1)
        result = self.run_client("-f")
        thread.join(1)
        self.assertEqual(0, result.returncode)
        self.assertTrue(received[0]["fast"])
        self.assertEqual([], received[0]["options"])
        self.assertEqual("options", received[1]["event"])
        self.assertEqual(["one", "two"], received[1]["options"])

    def test_fast_mode_cancel_does_not_wait_for_stdin_eof(self):
        thread, _ = self.serve_once({"version": 1, "ok": False, "error": "cancelled"})
        process = subprocess.Popen(
            [CLIENT, "-f"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)},
        )
        try:
            self.assertEqual(1, process.wait(1))
            thread.join(1)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(2)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_fast_mode_accepts_regular_file_stdin(self):
        thread, received = self.serve_once({"version": 1, "ok": True, "value": "two"}, request_count=2)
        source = Path(self.temp.name) / "options"
        source.write_text("one\ntwo\n")
        with source.open("rb") as stream:
            result = subprocess.run(
                [CLIENT, "-f"],
                stdin=stream,
                capture_output=True,
                env={**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)},
                check=False,
            )
        thread.join(1)
        self.assertEqual(0, result.returncode)
        self.assertEqual(["one", "two"], received[1]["options"])

    def test_fast_mode_rejects_an_oversized_early_response(self):
        thread, _ = self.serve_once(b"x" * (64 * 1024 + 1))
        process = subprocess.Popen(
            [CLIENT, "-f"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)},
        )
        try:
            self.assertEqual(1, process.wait(1))
            thread.join(1)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(2)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_cancel_and_socket_loss_exit_with_one(self):
        thread, _ = self.serve_once({"version": 1, "ok": False, "error": "cancelled"})
        cancelled = self.run_client()
        thread.join(1)
        thread, _ = self.serve_once(None)
        disconnected = self.run_client()
        thread.join(1)
        self.assertEqual(1, cancelled.returncode)
        self.assertEqual(1, disconnected.returncode)
        self.assertEqual(b"", cancelled.stdout)

    def test_rejects_oversized_input_before_connecting(self):
        result = self.run_client(input=b"x" * (1024 * 1024 + 1))
        self.assertEqual(1, result.returncode)
        self.assertIn(b"exceeds 1 MiB", result.stderr)

    def test_server_drops_an_unterminated_oversized_request(self):
        process = subprocess.Popen(
            [sys.executable, SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env={**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)},
        )
        try:
            for _ in range(50):
                if self.socket_path.exists():
                    break
                time.sleep(0.01)
            client = socket.socket(socket.AF_UNIX)
            client.settimeout(1)
            client.connect(str(self.socket_path))
            try:
                client.sendall(b"x" * (1024 * 1024 + 1))
                self.assertEqual(b"", client.recv(1))
            finally:
                client.close()
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait(2)
            process.stdin.close()
            process.stdout.close()

    def test_quickshell_shows_options_before_a_query_is_entered(self):
        repository = Path(__file__).parents[1]
        controller = (repository / "shell/modules/LauncherMainController.qml").read_text(encoding="utf-8")
        surface = (repository / "shell/modules/LauncherMainSurface.qml").read_text(encoding="utf-8")
        self.assertIn("if (!query.length && !dmenuMode)", controller)
        self.assertIn("controller.dmenuMode && controller.results.length", surface)


if __name__ == "__main__":
    unittest.main()
