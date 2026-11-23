"""Behavioural tests for the bloxd Rust daemon (dmenu, status contracts, bar-daemon)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
BLOXD = REPO_ROOT / "shell/native/qml/Blox/Services/bloxd"
CONTRACTS = json.loads((REPO_ROOT / "shell/scripts/contracts/status.json").read_text(encoding="utf-8"))
VALIDATE = REPO_ROOT / "shell/scripts/validate-status.py"


class BloxdTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(BLOXD.is_file() and os.access(BLOXD, os.X_OK), f"Missing {BLOXD}; run make native-services")

    def test_status_subcommands_match_contracts(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("validate_status", VALIDATE)
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)

        for name in ("system", "brightness", "touchpad", "caffeine", "workspaces"):
            with self.subTest(domain=name):
                completed = subprocess.run(
                    [str(BLOXD), "status", name],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(0, completed.returncode, completed.stderr)
                payload = json.loads(completed.stdout)
                spec_obj = CONTRACTS[name]
                errors: list[str] = []
                validator.validate_fields(name, payload, spec_obj.get("required", {}), errors)
                validator.validate_optional(name, payload, spec_obj.get("optional", {}), errors)
                validator.validate_items(name, payload, spec_obj.get("items", {}), errors)
                validator.validate_children(name, payload, spec_obj.get("children", {}), errors)
                validator.validate_enum(name, payload, spec_obj.get("enum", {}), errors)
                self.assertEqual([], errors)

        nl = subprocess.run([str(BLOXD), "status", "night-light"], capture_output=True, text=True, timeout=5, check=True)
        nl_payload = json.loads(nl.stdout)
        self.assertIn(nl_payload["mode"], ("on", "off", "auto"))
        self.assertIsInstance(nl_payload["active"], bool)
        self.assertIsInstance(nl_payload["available"], bool)

    def test_dmenu_server_handles_request_update_busy_and_abandon(self):
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="bloxd-") as tmp:
            runtime = Path(tmp)
            sock_path = runtime / "blox-launcher/dmenu.sock"
            proc = subprocess.Popen(
                [str(BLOXD), "dmenu", "--no-parent-guard"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={**os.environ, "XDG_RUNTIME_DIR": str(runtime)},
            )
            try:
                deadline = time.monotonic() + 3.0
                while not sock_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(sock_path.exists(), "dmenu socket did not appear")

                # 1. Request + fast-mode update + selection response
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(2.0)
                client.connect(str(sock_path))
                client.sendall(json.dumps({"version": 1, "options": [], "prompt": "Pick", "fast": True}).encode() + b"\n")
                first = json.loads(proc.stdout.readline())
                self.assertEqual("request", first["event"])
                self.assertEqual("Pick", first["prompt"])

                # Competing client while active gets busy immediately.
                busy_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                busy_client.settimeout(2.0)
                busy_client.connect(str(sock_path))
                busy_reply = json.loads(busy_client.recv(4096).decode().strip())
                self.assertFalse(busy_reply["ok"])
                self.assertEqual("busy", busy_reply["error"])
                busy_client.close()

                client.sendall(json.dumps({"version": 1, "event": "options", "options": ["alpha", "beta"]}).encode() + b"\n")
                updated = json.loads(proc.stdout.readline())
                self.assertEqual("update", updated["event"])
                self.assertEqual(["alpha", "beta"], updated["options"])

                proc.stdin.write(json.dumps({"value": "beta", "cancelled": False}).encode() + b"\n")
                proc.stdin.flush()
                reply = json.loads(client.recv(4096).decode().strip())
                self.assertTrue(reply["ok"])
                self.assertEqual("beta", reply["value"])
                client.close()

                # 2. Client disconnect announces abandoned
                client2 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client2.settimeout(2.0)
                client2.connect(str(sock_path))
                client2.sendall(json.dumps({"version": 1, "options": ["one"]}).encode() + b"\n")
                self.assertEqual("request", json.loads(proc.stdout.readline())["event"])
                client2.close()
                abandoned = json.loads(proc.stdout.readline())
                self.assertEqual("abandoned", abandoned["event"])
            finally:
                proc.stdin.close()
                proc.stdout.close()
                proc.stderr.close()
                proc.wait(timeout=3)

    def test_bar_daemon_streams_initial_domains_and_responds_to_refresh(self):
        proc = subprocess.Popen(
            [str(BLOXD), "bar-daemon", "--no-parent-guard"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            seen: dict[str, dict] = {}
            for _ in range(6):
                line = proc.stdout.readline()
                self.assertTrue(line, "bar-daemon closed early")
                msg = json.loads(line)
                seen[msg["domain"]] = msg["data"]
            for domain in ("workspaces", "system", "brightness", "touchpad", "nightLight", "caffeine"):
                self.assertIn(domain, seen)

            proc.stdin.write(json.dumps({"cmd": "refresh", "domain": "system"}) + "\n")
            proc.stdin.flush()
            refreshed = json.loads(proc.stdout.readline())
            self.assertEqual("system", refreshed["domain"])
            self.assertIn("cpuUtil", refreshed["data"])
        finally:
            proc.stdin.close()
            proc.stdout.close()
            proc.stderr.close()
            proc.wait(timeout=3)

    def test_theme_list_and_show_match_python_themectl(self):
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="bloxd-themes-") as tmp:
            user_dir = Path(tmp) / "user"
            user_themes = user_dir / "themes"
            user_themes.mkdir(parents=True)
            sample = json.loads((REPO_ROOT / "themes/builtin/catppuccin-mocha.json").read_text(encoding="utf-8"))
            sample["id"] = "rust-parity-custom"
            sample["name"] = "Rust Parity Custom"
            (user_themes / "rust-parity-custom.json").write_text(json.dumps(sample), encoding="utf-8")

            env = {
                **os.environ,
                "BLOX_DATA_DIR": str(REPO_ROOT / "themes"),
                "BLOX_USER_DATA_DIR": str(user_dir),
            }
            py_list = json.loads(
                subprocess.run([str(REPO_ROOT / "themes/bin/themectl"), "list", "--json"],
                               env=env, capture_output=True, text=True, check=True).stdout
            )
            rs_list = json.loads(
                subprocess.run([str(BLOXD), "theme", "list", "--json"],
                               env=env, capture_output=True, text=True, check=True).stdout
            )
            self.assertEqual(py_list, rs_list)

            for theme_id in ("catppuccin-mocha", "rust-parity-custom"):
                with self.subTest(theme_id=theme_id):
                    py_show = json.loads(
                        subprocess.run([str(REPO_ROOT / "themes/bin/themectl"), "show", theme_id, "--json"],
                                       env=env, capture_output=True, text=True, check=True).stdout
                    )
                    rs_show = json.loads(
                        subprocess.run([str(BLOXD), "theme", "show", theme_id, "--json"],
                                       env=env, capture_output=True, text=True, check=True).stdout
                    )
                    self.assertEqual(py_show, rs_show)

    def test_clipboard_ingest_is_compatible_with_python_store(self):
        import importlib.util
        from io import BytesIO
        from PIL import Image

        spec = importlib.util.spec_from_file_location(
            "clipboard_store", REPO_ROOT / "shell/scripts/launcher/clipboard_store.py"
        )
        clipboard_store = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(clipboard_store)

        with tempfile.TemporaryDirectory(dir="/tmp", prefix="bloxd-clip-") as tmp:
            root = Path(tmp) / "store"
            env = {**os.environ, "XDG_RUNTIME_DIR": tmp}

            # 1. Plain text + dedup
            r1 = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "text/plain;charset=utf-8"],
                                input=b"hello rust clipboard", env=env, capture_output=True, check=True)
            j1 = json.loads(r1.stdout)
            self.assertTrue(j1["ok"])
            r2 = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "text/plain;charset=utf-8"],
                                input=b"hello rust clipboard", env=env, capture_output=True, check=True)
            self.assertEqual(j1["id"], json.loads(r2.stdout)["id"])

            # 2. File URI canonicalisation & deduplication across text/plain vs text/uri-list
            sample_file = Path(tmp) / "note.txt"
            sample_file.write_text("hi")
            f1 = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "text/plain;charset=utf-8"],
                                input=sample_file.as_uri().encode(), env=env, capture_output=True, check=True)
            f2 = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "text/uri-list"],
                                input=(sample_file.as_uri() + "\n").encode(), env=env, capture_output=True, check=True)
            self.assertEqual(json.loads(f1.stdout)["id"], json.loads(f2.stdout)["id"])

            # 3. Valid PNG accepted, corrupt/huge PNG rejected, sensitive skipped
            buf = BytesIO()
            Image.new("RGB", (8, 6), (10, 20, 30)).save(buf, format="PNG")
            img_ok = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "image/png"],
                                    input=buf.getvalue(), env=env, capture_output=True, check=True)
            self.assertIsNotNone(json.loads(img_ok.stdout)["id"])

            big = BytesIO()
            Image.new("1", (5000, 4000)).save(big, format="PNG")
            img_bad = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "image/png"],
                                     input=big.getvalue(), env=env, capture_output=True, check=True)
            self.assertEqual("unsupported-image", json.loads(img_bad.stdout)["skipped"])

            sens = subprocess.run([str(BLOXD), "clipboard-ingest", "--root", str(root), "--mime", "text/plain", "--sensitive"],
                                  input=b"secret", env=env, capture_output=True, check=True)
            self.assertEqual("sensitive", json.loads(sens.stdout)["skipped"])

            # 4. Python Store reads back everything Rust wrote (including FTS search & file metadata)
            store = clipboard_store.Store(root)
            try:
                rows, _ = store.list(limit=20)
                self.assertEqual(3, len(rows))
                search_rows, _ = store.list(query="rust")
                self.assertEqual(1, len(search_rows))
                self.assertEqual(2, search_rows[0]["use_count"])
                uri_rows = [r for r in rows if r["mime"] == "text/uri-list"]
                self.assertEqual(str(sample_file), uri_rows[0]["file_path"])
            finally:
                store.db.close()


if __name__ == "__main__":
    unittest.main()
