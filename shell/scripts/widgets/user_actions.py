#!/usr/bin/env python3
"""Finite Todo/calendar actions. Only GUI launches leave the caller's owned group."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timedelta
import fcntl
import json
import locale
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

CONTEXT_ENV = "BLOX_WIDGET_ACTION_CONTEXT"
MAX_CONTEXT_BYTES = 128
MAX_FILE_BYTES = 1024 * 1024
CALENDAR_FILES = ("2-gcal.md", "80-today.md", "81-week.md", "99-gcal_week.md")
ADDRESS = re.compile(r"0x[0-9a-fA-F]{1,16}\Z")
OPERATIONS = {("todo", "next"), ("todo", "edit"), ("calendar", "next"), ("calendar", "open")}


class ActionError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


def workspace_context(environment):
    """Accept only the fixed host field. No focus lookup or implicit workspace."""
    raw = environment.get(CONTEXT_ENV, "")
    if len(raw.encode("utf-8")) > MAX_CONTEXT_BYTES:
        raise ActionError("Source workspace context is too large", "invalid-context")

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Duplicate context key")
            value[key] = item
        return value

    try:
        value = json.loads(raw, object_pairs_hook=unique)
    except (ValueError, TypeError):
        raise ActionError("Missing or invalid source workspace context", "invalid-context") from None
    if not isinstance(value, dict) or set(value) != {"workspaceId"}:
        raise ActionError("Expected exactly workspaceId in source context", "invalid-context")
    workspace = value["workspaceId"]
    if type(workspace) is not int or not 1 <= workspace <= 2147483647:
        raise ActionError("Launcher supports positive numeric source workspaces only", "unavailable")
    return workspace


def read_text(path, limit=MAX_FILE_BYTES):
    """Bound local reads, including selection files that are untrusted path data."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ActionError("Local action input is not a regular file", "invalid-data")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ActionError("Local action input exceeds its byte limit", "invalid-data")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise ActionError("Local action input is not UTF-8", "invalid-data") from None


def atomic_write(path, text):
    """Publish a complete file beside its destination, without following its symlink."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix="." + path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class Runtime:
    """Inject this boundary in tests. Finite commands inherit the action process group."""
    clock = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)
    now = staticmethod(datetime.now)

    def __init__(self, environment):
        self.environment = dict(environment)

    def run(self, argv, timeout):
        # No shell, session, service or background child here. The outer finite
        # owner must kill the inherited group on completion and cancellation.
        with subprocess.Popen(argv, env=self.environment, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            output = {"stdout": bytearray(), "stderr": bytearray()}
            deadline = self.clock() + timeout
            try:
                with selectors.DefaultSelector() as selector:
                    for name, stream in (("stdout", child.stdout), ("stderr", child.stderr)):
                        os.set_blocking(stream.fileno(), False)
                        selector.register(stream, selectors.EVENT_READ, name)
                    total = 0
                    while selector.get_map() or child.poll() is None:
                        remaining = deadline - self.clock()
                        if remaining <= 0:
                            raise ActionError("Finite child timed out", "timeout")
                        for key, _ in selector.select(min(remaining, .05)):
                            data = os.read(key.fd, 65536)
                            if not data:
                                selector.unregister(key.fileobj)
                                continue
                            total += len(data)
                            if total > MAX_FILE_BYTES:
                                raise ActionError("Finite child output exceeds 1 MiB", "overflow")
                            output[key.data].extend(data)
                return subprocess.CompletedProcess(argv, child.wait(),
                    output["stdout"].decode("utf-8", errors="replace"),
                    output["stderr"].decode("utf-8", errors="replace"))
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait()

    def launch(self, argv, workspace, launch_id):
        # Import lazily. Merely importing this helper must not load GUI libraries.
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "launcher"))
        from desktop_exec import active_cursor_environment, launch_detached
        environment = dict(self.environment)
        environment.pop(CONTEXT_ENV, None)
        environment.update(active_cursor_environment())
        return launch_detached(argv, None, environment, workspace_id=workspace,
                               launch_id=launch_id, timeout_seconds=2)

    def clients(self):
        result = self.run(["hyprctl", "clients", "-j"], .5)
        try:
            value = json.loads(result.stdout)
        except ValueError:
            value = None
        if result.returncode or not isinstance(value, list) or any(not isinstance(w, dict) for w in value):
            raise ActionError("Cannot read compositor windows", "unavailable")
        return value

    def process_launch_id(self, pid):
        if type(pid) is not int or pid <= 0:
            return None
        try:
            data = (Path("/proc") / str(pid) / "environ").read_bytes()
        except OSError:
            return None
        prefix = b"BLOX_LAUNCH_ID="
        return next((part[len(prefix):].decode("ascii", errors="replace")
                     for part in data.split(b"\0") if part.startswith(prefix)), None)

    def dispatch(self, expression):
        result = self.run(["hyprctl", "dispatch", expression], .5)
        if result.returncode:
            raise ActionError("Compositor action failed", "unavailable")


class UserActions:
    def __init__(self, environment, runtime):
        self.environment = dict(environment)
        self.runtime = runtime
        self.home = self._absolute(environment.get("HOME", ""))
        self.todo = self.home / "Documents/todo"
        self.state = self._absolute(environment.get("XDG_STATE_HOME") or str(self.home / ".local/state")) / "quickshell/widgets"
        self.locks = self._absolute(environment.get("XDG_RUNTIME_DIR") or environment.get("XDG_CACHE_HOME")
                                    or str(self.home / ".cache")) / "quickshell"
        self.cache = self.home / ".cache/gcal_script"
        self.result = {"ok": False, "code": "failed", "message": "", "launchAccepted": False,
                       "placementVerified": False}

    @staticmethod
    def _absolute(value):
        if not value or not Path(value).is_absolute() or "\0" in value:
            raise ActionError("Action data directories must be absolute", "invalid-data")
        return Path(value)

    @contextmanager
    def lock(self, name, wait=2):
        self.locks.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.locks / name,
                     os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ActionError("Action lock is not a regular file", "invalid-data")
            deadline = self.runtime.clock() + wait
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if self.runtime.clock() >= deadline:
                        raise ActionError("Action selection or generation is busy", "busy")
                    self.runtime.sleep(min(.05, max(0, deadline - self.runtime.clock())))
            yield
        finally:
            os.close(fd)

    def target(self, path):
        """Only top-level Markdown paths, including a missing creatable default."""
        path = Path(path)
        if path.parent != self.todo or path.suffix != ".md" or "\0" in str(path):
            raise ActionError("Selection is outside the Todo root or is not Markdown", "invalid-data")
        # The Todo root itself must not redirect to another directory.
        try:
            if self.todo.resolve() != self.todo.absolute():
                raise ActionError("Todo root contains an escaping symlink", "invalid-data")
            resolved = path.resolve()
        except RuntimeError:
            raise ActionError("Todo target contains a symlink loop", "invalid-data") from None
        if resolved.parent != self.todo or resolved.suffix != ".md":
            raise ActionError("Todo target escapes its root", "invalid-data")
        if path.exists() and not path.is_file():
            raise ActionError("Todo target is not a regular file", "invalid-data")
        return path

    def selection(self, name, default):
        try:
            return read_text(self.state / name, 4096).rstrip("\n")
        except FileNotFoundError:
            return str(default)

    def todo_files(self):
        self.target(self.todo / "1-todo.md")
        if not self.todo.exists():
            return []
        files = [p for p in self.todo.iterdir() if p.suffix == ".md" and p.name not in CALENDAR_FILES
                 and not p.is_symlink() and p.is_file()]
        # The baseline uses sort in the inherited locale.
        return sorted(files, key=lambda p: locale.strxfrm(str(p)))

    def next_selection(self, calendar=False):
        name = "gcal-current" if calendar else "todo-current"
        with self.lock("widget-gcal.lock" if calendar else "widget-todo.lock"):
            self.todo.mkdir(parents=True, exist_ok=True)
            files = ([self.target(self.todo / name) for name in CALENDAR_FILES]
                     if calendar else self.todo_files())
            if not files:
                self.result["selectedFile"] = str(self.target(self.todo / "1-todo.md"))
                return
            current = self.selection(name, files[0])
            # Unknown state advances to the first entry. Missing state advances
            # from the first entry, preserving the original first-click behaviour.
            paths = list(map(str, files))
            index = paths.index(current) if current in paths else -1
            selected = files[(index + 1) % len(files)]
            atomic_write(self.state / name, str(selected) + "\n")
            self.result["selectedFile"] = str(selected)
        if calendar:
            self.refresh(generated=True)

    def editor_dimensions(self, selected):
        files = self.todo_files()
        position = files.index(selected) + 1 if selected in files else 1
        try:
            content = read_text(selected).rstrip("\n")
        except FileNotFoundError:
            content = "File not found"
        # Command substitution removes trailing newlines; printf adds one back.
        text = f"# {selected.name} {position}/{len(files)}\n{content}".rstrip("\n")
        lines = text.split("\n")
        return max(200, max(map(len, lines)) * 9 + 40), max(80, len(lines) * 22 + 40)

    def handoff(self, argv, workspace):
        launch_id = "widget-action-" + uuid.uuid4().hex
        try:
            code = self.runtime.launch(argv, workspace, launch_id)
        except subprocess.TimeoutExpired:
            self.result["launchAccepted"] = None
            raise ActionError("Application handoff is uncertain; it will not be retried", "timeout") from None
        if code:
            raise ActionError("Application handoff failed", "unavailable")
        self.result["launchAccepted"] = True
        return launch_id

    def verified_window(self, window, launch_id, workspace, old_addresses):
        return (isinstance(window.get("address"), str) and ADDRESS.fullmatch(window["address"])
                and window["address"] not in old_addresses
                and window.get("class") == "quickshell_todo"
                and isinstance(window.get("workspace"), dict)
                and type(window["workspace"].get("id")) is int
                and window["workspace"]["id"] == workspace
                and type(window.get("pid")) is int
                and self.runtime.process_launch_id(window["pid"]) == launch_id)

    def edit(self):
        workspace = workspace_context(self.environment)
        with self.lock("widget-todo.lock"):
            selected = self.target(self.selection("todo-current", self.todo / "1-todo.md"))
            width, height = self.editor_dimensions(selected)
        micro = self.environment.get("MICRO_BIN") or str(self.home / ".local/bin/micro")
        if not Path(micro).is_file() or not os.access(micro, os.X_OK):
            micro = shutil.which("micro", path=self.environment.get("PATH", ""))
        if not micro:
            raise ActionError("Micro is unavailable", "unavailable")
        micro = str(Path(micro).resolve())
        old_addresses = {w["address"] for w in self.runtime.clients() if isinstance(w.get("address"), str)}
        self.target(selected)
        launch_id = self.handoff(["kitty", "--class", "quickshell_todo", "--title", "quickshell_todo",
                                  micro, str(selected)], workspace)
        deadline = self.runtime.clock() + 5
        window = None
        for attempt in range(50):
            if self.runtime.clock() >= deadline:
                break
            matches = [w for w in self.runtime.clients()
                       if self.verified_window(w, launch_id, workspace, old_addresses)]
            if self.runtime.clock() > deadline:
                break
            if len(matches) == 1:
                window = matches[0]
                break
            if self.runtime.clock() >= deadline:
                break
            if attempt != 49:
                self.runtime.sleep(min(.1, max(0, deadline - self.runtime.clock())))
        if window is None:
            raise ActionError("Editor launch accepted but source workspace placement was not verified", "unavailable")
        self.runtime.sleep(.15)
        selector = '"address:' + window["address"] + '"'
        for repeat in range(2):
            # Recheck identity before addressing a window after each startup wait.
            live = next((w for w in self.runtime.clients() if w.get("address") == window["address"]), {})
            if not self.verified_window(live, launch_id, workspace, old_addresses) or live.get("pid") != window["pid"]:
                raise ActionError("Editor window identity changed during placement", "unavailable")
            for expression in (
                f'hl.dsp.window.float({{ action = "enable", window = {selector} }})',
                f'hl.dsp.focus({{ window = {selector} }})',
                f'hl.dsp.window.resize({{ x = {width}, y = {height}, window = {selector} }})',
                f'hl.dsp.window.move({{ x = 60, y = 20, window = {selector} }})',
            ):
                self.runtime.dispatch(expression)
            if repeat == 0:
                self.runtime.sleep(.05)
        live = next((w for w in self.runtime.clients() if w.get("address") == window["address"]), {})
        if (not self.verified_window(live, launch_id, workspace, old_addresses)
                or live.get("pid") != window["pid"] or live.get("floating") is not True
                or live.get("size") != [width, height] or live.get("at") != [60, 20]):
            raise ActionError("Editor geometry was not verified", "unavailable")
        self.result["placementVerified"] = True

    def open_calendar(self):
        workspace = workspace_context(self.environment)
        errors = []
        try:
            self.handoff(["zen-browser", "calendar.google.com"], workspace)
        except (ActionError, OSError) as error:
            errors.append(error)
        # Browser reuse prevents claiming that its window followed the launch rule.
        try:
            self.runtime.dispatch('hl.dsp.focus({ workspace = 1 })')
        except (ActionError, OSError) as error:
            errors.append(error)
        try:
            self.refresh(generated=False)
        except (ActionError, OSError) as error:
            errors.append(error)
        if errors:
            if len(errors) == 1 and isinstance(errors[0], ActionError):
                raise errors[0]
            raise ActionError("; ".join(map(str, errors)))

    def refresh(self, generated):
        """Replace unsafe shell descendants with synchronous typed invocations."""
        with self.lock("generated-refresh.lock", wait=0):
            self.todo.mkdir(parents=True, exist_ok=True)
            for name in CALENDAR_FILES:
                self.target(self.todo / name)
            errors = []
            try:
                self.refresh_calendar()
            except (ActionError, OSError) as error:
                errors.append(str(error))
            base = self.environment.get("EXPENSES_API_BASE_URL", "")
            if generated and base:
                try:
                    self.refresh_expenses(base)
                except (ActionError, OSError) as error:
                    errors.append(str(error))
            if errors:
                raise ActionError("; ".join(errors))

    def refresh_expenses(self, base):
        errors = []
        # URLs are literal argv, including punctuation. -- ends curl option parsing.
        requests = [(8, ["-X", "POST"], "/api/exports/regenerate", None),
                    (6, [], "/api/chart/today-text", "80-today.md"),
                    (6, [], "/api/chart/week-text", "81-week.md")]
        for cap, extra, suffix, filename in requests:
            try:
                result = self.runtime.run(["curl", "-fsS", "--connect-timeout", "2", "--max-time", str(cap),
                                           *extra, "--", base + suffix], cap + 1)
                if result.returncode:
                    raise ActionError("Expense refresh failed")
                if filename:
                    atomic_write(self.target(self.todo / filename), result.stdout)
            except (ActionError, OSError) as error:
                errors.append(str(error))
        if errors:
            raise ActionError("; ".join(errors))

    def refresh_calendar(self):
        self.cache.mkdir(parents=True, exist_ok=True)
        now = self.runtime.now()
        # Monday=0. Saturday and Sunday both include the following Sunday.
        end = (now + timedelta(days=8 if now.weekday() == 5 else 7)).strftime("%Y-%m-%d") if now.weekday() >= 5 else "sunday"
        errors = []
        notified = False
        for until, cache_name, output_name in (("tomorrow", "day.cache", "2-gcal.md"),
                                               (end, "week.cache", "99-gcal_week.md")):
            try:
                result = self.runtime.run(["gcalcli", "agenda", "--military", "--details=end", "--details=location",
                                           "--width=300", "today", until], 25)
                raw = result.stdout.rstrip("\n")
                if result.returncode or not raw:
                    status = "offline"
                    diagnostic = ""
                    if re.search(r"invalid_grant.*Token has been expired or revoked", result.stderr):
                        status = "expired"
                        if not notified:
                            notified = True
                            # notify-send's server retains the notification. No
                            # detached auth script, service or shell callback.
                            workspace = workspace_context(self.environment)
                            self.handoff(["notify-send", "--app-name=gcalcli", "--urgency=critical",
                                          "Google Calendar auth expired", "Re-authenticate with gcalcli init."], workspace)
                    elif result.stderr.strip() and not re.search(
                            r"ServerNotFoundError|gaierror|Network is unreachable|Name or service not known|Connection refused|Timeout|ConnectionError|Failed to establish a new connection|NewConnectionError|nodename nor servname provided",
                            result.stderr, re.IGNORECASE):
                        status, diagnostic = "error", result.stderr.strip().split("\n")[-1]
                    try:
                        cached = read_text(self.cache / cache_name)
                    except FileNotFoundError:
                        cached = ""
                    text = render_calendar(cached, now, status, diagnostic) if cached else {
                        "offline": "󰖪 No Data\n", "expired": "󱦃 No Data\n", "error": f" {diagnostic}\n"}[status]
                    atomic_write(self.target(self.todo / output_name), text)
                    errors.append("Calendar refresh failed: " + status)
                else:
                    atomic_write(self.cache / cache_name, raw + "\n")
                    atomic_write(self.target(self.todo / output_name), render_calendar(raw, now))
            except (ActionError, OSError) as error:
                errors.append(str(error))
        if errors:
            raise ActionError("; ".join(errors))

    def execute(self, operation):
        if tuple(operation) not in OPERATIONS:
            raise ActionError("Expected todo next, todo edit, calendar next or calendar open", "invalid-data")
        operation = tuple(operation)
        if operation == ("todo", "next"):
            self.next_selection()
        elif operation == ("todo", "edit"):
            self.edit()
        elif operation == ("calendar", "next"):
            self.next_selection(calendar=True)
        else:
            self.open_calendar()
        self.result.update(ok=True, code="ok")
        return self.result


def render_calendar(raw, now, status="online", diagnostic=""):
    """Keep the generated Markdown text contract without sed/awk shell pipelines."""
    text = re.sub(r"<br/?>", "", raw)
    text = re.sub(r"[<>]", "", text)
    text = re.sub(r"\x1b\[[0-9;]*35m", "▒", text)
    text = re.sub(r"\x1b\[[0-9;]*36m", "▕", text)
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    text = re.sub(r"([▒▕])", r"\n\1", text)
    output = {"offline": ["󰖪 "], "expired": ["󱦃 "], "error": [" " + diagnostic]}.get(status, [])
    buffer, university, today = "", False, False

    def flush():
        nonlocal buffer
        if buffer:
            output.append(buffer)
            buffer = ""

    for line in text.split("\n"):
        line = line.strip(" \t\r")
        if not line:
            continue
        if re.match(r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]+", line):
            flush()
            today = re.sub(r" +", " ", line).startswith(now.strftime("%a %b %d"))
            match = re.search(r" [0-9]*:[0-9]{2}", line)
            if match:
                output.append(line[:match.start()])
                line = line[match.start():].lstrip()
            else:
                output.append(line)
                continue
        symbol = line[0]
        if symbol in "▒▕":
            line = line[1:]
        elif re.match(r"[0-9:]", line):
            symbol = "▕"
        match = re.search(r"([0-9]*):([0-9]{2})[ \t]*-[ \t]*([0-9]*):([0-9]{2})", line)
        if match:
            flush()
            sh, sm, eh, em = match.groups()
            sh, eh = int(sh or 0), int(eh or 0)
            rest = line[match.end():].strip()
            university = symbol == "▒" or bool(re.match(r"^[A-Z0-9]+ - ", rest))
            modified = university and " - " in rest
            if modified:
                rest = rest.split(" - ", 1)[1]
            university = modified
            if today and sh <= now.hour < eh:
                symbol = "➡️"
            buffer = f"{symbol}  {sh:02d}:{sm}-{eh:02d}:{em}   {rest}"
            continue
        if line.startswith("Location:"):
            location = line[9:].strip()
            match = re.search(r"\(([^)]+)\)", location)
            if university and match:
                location = match[1]
            if buffer and location:
                buffer += "  " + location
    flush()
    return "\n".join(output) + ("\n" if output else "")


def main(argv=None, environment=None, runtime=None, output=None):
    argv = sys.argv[1:] if argv is None else argv
    environment = dict(os.environ if environment is None else environment)
    output = sys.stdout if output is None else output
    actions = None
    try:
        actions = UserActions(environment, runtime if runtime is not None else Runtime(environment))
        reply = actions.execute(argv)
    except (ActionError, OSError, ValueError, ImportError, subprocess.TimeoutExpired) as error:
        reply = actions.result if actions else {"launchAccepted": False, "placementVerified": False}
        reply.update(ok=False, code=getattr(error, "code", "unavailable"), message=str(error)[:512])
    output.write(json.dumps(reply, ensure_ascii=True) + "\n")
    return 0 if reply["ok"] else 75 if reply["code"] == "busy" else 1


if __name__ == "__main__":
    locale.setlocale(locale.LC_COLLATE, "")
    raise SystemExit(main())
