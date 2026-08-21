#!/usr/bin/env python3
import glob
import json
import os
import pickle
import pty
import re
import select
import shutil
import subprocess
import sys
import termios
import time


HOME = os.path.expanduser("~")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SECRET_DIR = os.path.join(HOME, "Documents", "Backup Files")
OAUTH_PATH = os.path.join(HOME, ".local", "share", "gcalcli", "oauth")


def notify(title, body, urgency="normal"):
    if shutil.which("notify-send"):
        subprocess.Popen(
            ["notify-send", "-u", urgency, "-a", "gcalcli", title, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    return data.get("installed") or data.get("web") or data


def current_client_id():
    try:
        with open(OAUTH_PATH, "rb") as handle:
            creds = pickle.load(handle)
        return getattr(creds, "client_id", None)
    except Exception:
        return None


def candidate_secret_files():
    override = os.environ.get("GCALCLI_CLIENT_SECRET_JSON")
    if override:
        return [os.path.expanduser(override)]

    patterns = [
        os.path.join(DEFAULT_SECRET_DIR, "real_client_secret*.json"),
        os.path.join(DEFAULT_SECRET_DIR, "client_secret*.json"),
    ]
    files = []
    for pattern in patterns:
        files.extend(glob.glob(pattern))
    return sorted(set(files), key=lambda path: os.path.getmtime(path), reverse=True)


def load_client_config():
    target_client_id = current_client_id()
    fallback = None

    for path in candidate_secret_files():
        try:
            config = read_json(path)
        except Exception:
            continue

        client_id = config.get("client_id")
        client_secret = config.get("client_secret")
        if not client_id or not client_secret:
            continue

        if fallback is None:
            fallback = (path, client_id, client_secret)
        if target_client_id and client_id == target_client_id:
            return path, client_id, client_secret

    if fallback:
        return fallback

    raise RuntimeError(
        "No usable gcalcli OAuth client JSON found. Set GCALCLI_CLIENT_SECRET_JSON "
        "or place real_client_secret*.json in ~/Documents/Backup Files."
    )


def open_auth_url(url):
    opener = shutil.which("zen-browser") or shutil.which("xdg-open")
    if not opener:
        print("\nNo zen-browser or xdg-open found. Open this URL manually:\n", url)
        return
    subprocess.Popen(
        [opener, url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def refresh_generated_notes():
    refresh_script = os.path.join(SCRIPT_DIR, "generated-refresh.sh")
    if os.path.exists(refresh_script):
        subprocess.run([refresh_script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def set_no_echo(fd):
    attrs = termios.tcgetattr(fd)
    attrs[3] = attrs[3] & ~termios.ECHO
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def run_gcalcli_init(client_id, client_secret):
    master_fd, slave_fd = pty.openpty()
    set_no_echo(slave_fd)

    process = subprocess.Popen(
        ["gcalcli", "init"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
    )
    os.close(slave_fd)

    transcript = ""
    sent_refresh = False
    sent_client_id = False
    sent_client_secret = False
    opened_url = False
    url_pattern = re.compile(r"https://accounts\.google\.com/[^\s'\"]+")

    try:
        while True:
            ready, _, _ = select.select([master_fd], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""

                if not chunk:
                    if process.poll() is not None:
                        break
                    continue

                text = chunk.decode("utf-8", errors="replace")
                print(text, end="", flush=True)
                transcript += text
                transcript = transcript[-12000:]

                if not sent_refresh and "Ignore and refresh?" in transcript:
                    os.write(master_fd, b"y\n")
                    sent_refresh = True

                if not sent_client_id and "Client ID:" in transcript:
                    os.write(master_fd, f"{client_id}\n".encode())
                    sent_client_id = True

                if not sent_client_secret and "Client Secret:" in transcript:
                    os.write(master_fd, f"{client_secret}\n".encode())
                    sent_client_secret = True

                if not opened_url:
                    match = url_pattern.search(transcript)
                    if match:
                        url = match.group(0)
                        print("\nOpening Google auth URL in zen-browser...\n", flush=True)
                        open_auth_url(url)
                        opened_url = True

            if process.poll() is not None:
                time.sleep(0.1)
                while True:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    print(chunk.decode("utf-8", errors="replace"), end="", flush=True)
                break
    finally:
        os.close(master_fd)

    return process.wait()


def main():
    try:
        path, client_id, client_secret = load_client_config()
    except Exception as exc:
        print(f"gcalcli auth setup failed: {exc}", file=sys.stderr)
        notify("Google Calendar auth setup failed", str(exc), "critical")
        return 1

    print(f"Using OAuth client JSON: {path}")
    print("Starting gcalcli init. The client ID/secret prompts will be filled automatically.")
    print("Finish the Google approval flow in Zen when it opens.\n")

    code = run_gcalcli_init(client_id, client_secret)
    if code == 0:
        print("\ngcalcli auth refreshed. Updating generated calendar notes...")
        refresh_generated_notes()
        notify("Google Calendar auth fixed", "gcalcli was re-authenticated and calendar notes were refreshed.")
    else:
        notify("Google Calendar auth failed", "gcalcli init did not complete successfully.", "critical")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
