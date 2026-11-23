"""PTY sessions owned by the shared widget broker, with bounded ANSI cell snapshots.

Commands are trusted user configuration, not a sandbox. Nothing invokes a shell
unless the command explicitly names one. No legacy entrypoint is imported.
"""
from __future__ import annotations

import atexit

import codecs
import errno
import fcntl
import math
import os
import re
import struct
import termios
import time
import unicodedata
import weakref

from . import ownership

MAX_COLUMNS = 240
MAX_ROWS = 100
MAX_CELLS = 12000
MAX_READ_BYTES = 65536
MAX_POLL_SECONDS = .01
CSI_FINAL = re.compile(r"[@-~]")


def _dimensions(columns, rows):
    if type(columns) is not int or type(rows) is not int or not 2 <= columns <= MAX_COLUMNS or not 1 <= rows <= MAX_ROWS or columns * rows > MAX_CELLS:
        raise ValueError("terminal dimensions exceed bounded grid")


class AnsiScreen:
    """Bounded ANSI/VT cells. Unsupported controls are consumed, never executed."""

    def __init__(self, rows: int, columns: int) -> None:
        _dimensions(columns, rows)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.wrap_pending = False
        self.rows = rows
        self.columns = columns
        self.cells = [[" "] * columns for _ in range(rows)]
        self.styles = [[(None, None, False, False, False)] * columns for _ in range(rows)]
        self.row = 0
        self.column = 0
        self.state = "text"
        self.csi = ""
        self.foreground_colour: str | None = None
        self.background_colour: str | None = None
        self.bold = False
        self.underline = False
        self.inverse = False
        self.scroll_top = 0
        self.scroll_bottom = rows - 1
        self.saved_cursor = (0, 0)
        self.main_buffer = None

    def _style(self) -> tuple:
        return (self.foreground_colour, self.background_colour, self.bold, self.underline, self.inverse)

    def _blank_row(self) -> tuple[list[str], list[tuple]]:
        return ([" "] * self.columns, [self._style()] * self.columns)

    def _reverse_index(self) -> None:
        if self.row == self.scroll_top:
            cells, styles = self._blank_row()
            self.cells.insert(self.scroll_top, cells)
            self.styles.insert(self.scroll_top, styles)
            del self.cells[self.scroll_bottom + 1]
            del self.styles[self.scroll_bottom + 1]
        else:
            self.row = max(self.scroll_top, self.row - 1)

    def _index(self) -> None:
        if self.row == self.scroll_bottom:
            del self.cells[self.scroll_top]
            del self.styles[self.scroll_top]
            cells, styles = self._blank_row()
            self.cells.insert(self.scroll_bottom, cells)
            self.styles.insert(self.scroll_bottom, styles)
        else:
            self.row = min(self.rows - 1, self.row + 1)

    def feed(self, data: bytes) -> None:
        for char in self.decoder.decode(data):
            if self.state == "escape":
                if char == "[":
                    self.state = "csi"
                    self.csi = ""
                elif char in "]P^_":
                    self.state = "string"
                elif char in "()*+":
                    self.state = "charset"
                elif char == "M":
                    self._reverse_index()
                    self.state = "text"
                elif char == "7":
                    self.saved_cursor = (self.row, self.column)
                    self.state = "text"
                elif char == "8":
                    self.row, self.column = self.saved_cursor
                    self.state = "text"
                else:
                    self.state = "text"
                continue
            if self.state == "charset":
                self.state = "text"
                continue
            if self.state == "string":
                if char in "\a\x1b":
                    self.state = "text" if char == "\a" else "string_escape"
                continue
            if self.state == "string_escape":
                self.state = "text" if char == "\\" else "string"
                continue
            if self.state == "csi":
                self.csi += char
                if CSI_FINAL.fullmatch(char):
                    self._csi(self.csi[:-1], char)
                    self.state = "text"
                elif len(self.csi) > 64:
                    self.state = "text"
                continue
            if char == "\x1b":
                self.state = "escape"
            elif char == "\r":
                self.column = 0
                self.wrap_pending = False
            elif char == "\n":
                self._index()
            elif char == "\b":
                self.column = max(0, self.column - 1)
            elif char == "\t":
                self.column = min(self.columns - 1, (self.column // 8 + 1) * 8)
            elif char >= " " and char != "\x7f":
                self._put(char)

    def _put(self, char: str) -> None:
        # Combining marks attach to one preceding cell. This is deliberately not
        # a full grapheme/emoji implementation. See TERMINAL.md.
        if unicodedata.combining(char):
            previous = self.column if self.wrap_pending else self.column - 1
            if previous >= 0:
                if self.cells[self.row][previous] == "" and previous:
                    previous -= 1
                self.cells[self.row][previous] = (self.cells[self.row][previous] + char)[:8]
            return
        width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if self.wrap_pending or self.column + width > self.columns:
            self.column = 0
            self._index()
        self.wrap_pending = False
        # Overwriting either half of a wide cell clears its other half.
        if self.cells[self.row][self.column] == "" and self.column:
            self.cells[self.row][self.column - 1] = " "
        if self.column + 1 < self.columns and self.cells[self.row][self.column + 1] == "":
            self.cells[self.row][self.column + 1] = " "
        self.cells[self.row][self.column] = char
        style = (self.foreground_colour, self.background_colour, self.bold, self.underline, self.inverse)
        self.styles[self.row][self.column] = style
        if width == 2 and self.column + 1 < self.columns:
            self.cells[self.row][self.column + 1] = ""
            self.styles[self.row][self.column + 1] = style
        end = self.column + width
        self.wrap_pending = end >= self.columns
        self.column = min(self.columns - 1, end)

    @staticmethod
    def _parameters(raw: str) -> list[int]:
        raw = raw.lstrip("?<=>")
        return [int(value) if value.isdigit() else 0 for value in raw.split(";")]

    def _csi(self, raw: str, final: str) -> None:
        self.wrap_pending = False
        values = self._parameters(raw)
        amount = values[0] or 1
        if raw.startswith("?") and final in ("h", "l"):
            if any(mode in (47, 1047, 1049) for mode in values):
                if final == "h" and self.main_buffer is None:
                    self.main_buffer = (self.cells, self.styles, self.row, self.column)
                    self.cells = [[" "] * self.columns for _ in range(self.rows)]
                    self.styles = [[self._style()] * self.columns for _ in range(self.rows)]
                    self.row = self.column = 0
                elif final == "l" and self.main_buffer is not None:
                    self.cells, self.styles, self.row, self.column = self.main_buffer
                    self.main_buffer = None
                    self.resize(self.columns, self.rows)
            return
        if final in "Hf":
            self.row = max(0, min(self.rows - 1, (values[0] or 1) - 1))
            self.column = max(0, min(self.columns - 1, (values[1] if len(values) > 1 else 1) - 1))
        elif final == "A":
            self.row = max(0, self.row - amount)
        elif final == "B":
            self.row = min(self.rows - 1, self.row + amount)
        elif final == "C":
            self.column = min(self.columns - 1, self.column + amount)
        elif final == "D":
            self.column = max(0, self.column - amount)
        elif final == "E":
            self.row = min(self.rows - 1, self.row + amount)
            self.column = 0
        elif final == "F":
            self.row = max(0, self.row - amount)
            self.column = 0
        elif final == "G":
            self.column = max(0, min(self.columns - 1, amount - 1))
        elif final == "d":
            self.row = max(0, min(self.rows - 1, amount - 1))
        elif final == "r":
            top = (values[0] or 1) - 1
            bottom = (values[1] if len(values) > 1 and values[1] else self.rows) - 1
            if 0 <= top < bottom < self.rows:
                self.scroll_top = top
                self.scroll_bottom = bottom
            else:
                self.scroll_top = 0
                self.scroll_bottom = self.rows - 1
            self.row = self.column = 0
        elif final == "s":
            self.saved_cursor = (self.row, self.column)
        elif final == "u":
            self.row, self.column = self.saved_cursor
        elif final == "J":
            mode = values[0]
            if mode == 2:
                self.cells = [[" "] * self.columns for _ in range(self.rows)]
                self.styles = [[self._style()] * self.columns for _ in range(self.rows)]
            elif mode == 0:
                self._erase_to_end()
            elif mode == 1:
                for row in range(self.row):
                    self.cells[row], self.styles[row] = self._blank_row()
                self.cells[self.row][:self.column + 1] = [" "] * (self.column + 1)
                self.styles[self.row][:self.column + 1] = [self._style()] * (self.column + 1)
        elif final == "K":
            mode = values[0]
            start, end = (0, self.columns) if mode == 2 else ((0, self.column + 1) if mode == 1 else (self.column, self.columns))
            self.cells[self.row][start:end] = [" "] * (end - start)
            self.styles[self.row][start:end] = [self._style()] * (end - start)
        elif final == "L":
            for _ in range(min(amount, self.scroll_bottom - self.row + 1)):
                cells, styles = self._blank_row()
                self.cells.insert(self.row, cells)
                self.styles.insert(self.row, styles)
                del self.cells[self.scroll_bottom + 1]
                del self.styles[self.scroll_bottom + 1]
        elif final == "M":
            for _ in range(min(amount, self.scroll_bottom - self.row + 1)):
                del self.cells[self.row]
                del self.styles[self.row]
                cells, styles = self._blank_row()
                self.cells.insert(self.scroll_bottom, cells)
                self.styles.insert(self.scroll_bottom, styles)
        elif final == "P":
            count = min(amount, self.columns - self.column)
            del self.cells[self.row][self.column:self.column + count]
            del self.styles[self.row][self.column:self.column + count]
            self.cells[self.row].extend([" "] * count)
            self.styles[self.row].extend([self._style()] * count)
        elif final == "@":
            count = min(amount, self.columns - self.column)
            self.cells[self.row][self.column:self.column] = [" "] * count
            self.styles[self.row][self.column:self.column] = [self._style()] * count
            del self.cells[self.row][self.columns:]
            del self.styles[self.row][self.columns:]
        elif final == "X":
            end = min(self.columns, self.column + amount)
            self.cells[self.row][self.column:end] = [" "] * (end - self.column)
            self.styles[self.row][self.column:end] = [self._style()] * (end - self.column)
        elif final == "m":
            self._sgr(values)

    def _erase_to_end(self) -> None:
        self.cells[self.row][self.column:] = [" "] * (self.columns - self.column)
        self.styles[self.row][self.column:] = [self._style()] * (self.columns - self.column)
        for row in range(self.row + 1, self.rows):
            self.cells[row] = [" "] * self.columns
            self.styles[row] = [self._style()] * self.columns

    @staticmethod
    def _ansi_colour(value: int, bright: bool = False) -> str:
        normal = ("#1d2021", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984")
        vivid = ("#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2")
        return (vivid if bright else normal)[value]

    def _sgr(self, values: list[int]) -> None:
        if not values:
            values = [0]
        index = 0
        while index < len(values):
            value = values[index]
            if value == 0:
                self.foreground_colour = self.background_colour = None
                self.bold = self.underline = self.inverse = False
            elif value == 1:
                self.bold = True
            elif value == 4:
                self.underline = True
            elif value == 24:
                self.underline = False
            elif value == 7:
                self.inverse = True
            elif value == 27:
                self.inverse = False
            elif value == 22:
                self.bold = self.underline = self.inverse = False
            elif value == 39:
                self.foreground_colour = None
            elif value == 49:
                self.background_colour = None
            elif 30 <= value <= 37:
                self.foreground_colour = self._ansi_colour(value - 30)
            elif 90 <= value <= 97:
                self.foreground_colour = self._ansi_colour(value - 90, True)
            elif 40 <= value <= 47:
                self.background_colour = self._ansi_colour(value - 40)
            elif 100 <= value <= 107:
                self.background_colour = self._ansi_colour(value - 100, True)
            elif value in (38, 48) and index + 4 < len(values) and values[index + 1] == 2:
                colour = "#{:02x}{:02x}{:02x}".format(*(max(0, min(255, n)) for n in values[index + 2:index + 5]))
                if value == 38:
                    self.foreground_colour = colour
                else:
                    self.background_colour = colour
                index += 4
            elif value in (38, 48) and index + 2 < len(values) and values[index + 1] == 5:
                number = max(0, min(255, values[index + 2]))
                if number < 16:
                    colour = self._ansi_colour(number % 8, number >= 8)
                elif number < 232:
                    number -= 16
                    levels = (0, 95, 135, 175, 215, 255)
                    colour = "#{:02x}{:02x}{:02x}".format(levels[number // 36], levels[(number // 6) % 6], levels[number % 6])
                else:
                    level = 8 + (number - 232) * 10
                    colour = "#{0:02x}{0:02x}{0:02x}".format(level)
                if value == 38:
                    self.foreground_colour = colour
                else:
                    self.background_colour = colour
                index += 2
            index += 1

    def resize(self, columns: int, rows: int) -> None:
        _dimensions(columns, rows)
        cells, styles = self.cells, self.styles
        self.columns, self.rows = columns, rows
        self.cells, self.styles = [], []
        for row in range(rows):
            blank, plain = self._blank_row()
            if row < len(cells):
                count = min(columns, len(cells[row]))
                blank[:count], plain[:count] = cells[row][:count], styles[row][:count]
            self.cells.append(blank)
            self.styles.append(plain)
        self.row, self.column = min(self.row, rows - 1), min(self.column, columns - 1)
        self.scroll_top, self.scroll_bottom = 0, rows - 1
        self.saved_cursor = (min(self.saved_cursor[0], rows - 1), min(self.saved_cursor[1], columns - 1))
        self.wrap_pending = False

    def runs(self, row: int, start: int = 0, end: int | None = None) -> list[dict]:
        end = self.columns if end is None else end
        result = []
        while start < end:
            style = self.styles[row][start]
            stop = start + 1
            while stop < end and self.styles[row][stop] == style:
                stop += 1
            cells = self.cells[row][start:stop]
            result.append(dict(column=start, cells=cells, text="".join(cells),
                               foreground=style[0], background=style[1], bold=style[2],
                               underline=style[3], inverse=style[4]))
            start = stop
        return result


_SESSIONS = weakref.WeakSet()


def close_sessions() -> None:
    """Broker shutdown hooks must call this, including SIGTERM handling."""
    for session in list(_SESSIONS):
        session.close()


atexit.register(close_sessions)


class TerminalLaunchError(OSError):
    """PTY allocation or process creation failed, rather than broker infrastructure."""


class TerminalSession:
    """One attempt's PTY. The selector borrows descriptors owned here.

    A snapshot with readiness=partial contains observed bytes, not proof that a
    live TUI completed a frame. Only EOF plus process exit yields settled.
    """

    def __init__(self, options: dict, generation: int, clock=time.monotonic):
        from .model import validate_settings
        options = validate_settings("terminal", options)
        command = options["command"]
        cwd = options["workingDirectory"] or None
        env = options["environment"]
        columns, rows = options["columns"], options["rows"]
        runtime = options["maxRuntimeSeconds"]
        if type(generation) is not int or generation < 0:
            raise ValueError("invalid terminal generation")
        self.generation, self.sequence = generation, 0
        self.screen = AnsiScreen(rows, columns)
        self.clock = clock
        self.started = clock()
        self.exited_at = None
        self.deadline = self.started + runtime if runtime else math.inf
        self.total_bytes, self.eof, self.closed = 0, False, False
        self.reason = None
        self._previous = None
        self._dirty = False
        self._exit_reported = False
        self.process = None
        self.fd = -1
        self.exit_fd = None
        self.before_close = None
        environment = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor")
        environment.update(env)
        try:
            self.process = ownership.launch(command, environment, cwd or '',
                self.deadline if math.isfinite(self.deadline) else None,
                terminal={'columns': columns, 'rows': rows})
        except ownership.InvocationLaunchError as error:
            raise TerminalLaunchError(error.errno, 'Terminal could not be started') from error
        # Watch/descriptor failures after admission are infrastructure failures,
        # not configured-command failures eligible for automatic recovery.
        try:
            self.fd = self.process.fd
            self.process.fd = -1
            os.set_blocking(self.fd, False)
            self.exit_fd = os.dup(self.process.exit_fd)
        except BaseException:
            self.close()
            raise
        _SESSIONS.add(self)

    @property
    def readable_fd(self):
        return self.fd if not self.closed and not self.eof else None

    @property
    def dirty(self):
        return self._dirty

    def expire(self, now):
        if not self.closed and now >= self.deadline:
            self.reason = "runtime-limit"
            self.close()
            self._dirty = True

    def ingest(self, until, byte_limit=MAX_READ_BYTES) -> tuple[int, bool]:
        """Parse ordered bytes without building rows. False means more may remain.

        The broker supplies a shared deadline and rotates at 512-byte boundaries.
        A single ANSI operation remains cooperative, rather than pre-emptible.
        """
        read_bytes = 0
        while self.readable_fd is not None and read_bytes < byte_limit and self.clock() < until:
            try:
                data = os.read(self.fd, min(512, byte_limit - read_bytes))
            except BlockingIOError:
                return read_bytes, True
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            if not data:
                self.screen.feed(b"")
                tail = self.screen.decoder.decode(b"", final=True)
                if tail:
                    self.screen.feed(tail.encode())
                    self._dirty = True
                self.eof = True
                self.check_exit()
                break
            read_bytes += len(data)
            self.total_bytes += len(data)
            self.screen.feed(data)
            self._dirty = True
        return read_bytes, self.eof or self.closed

    def check_exit(self):
        """Reap only this session's direct child, including EOF-before-exit."""
        exited = self.process.poll() is not None
        if exited and self.exited_at is None:
            self.exited_at = self.clock()
            self._dirty = True
        if self.eof and exited and not self._exit_reported:
            self._exit_reported = True
            self._dirty = True
            self.deadline = math.inf
        return exited

    def release_exit_watch(self):
        """Call after unregistering the borrowed child-exit descriptor."""
        if self.exit_fd is not None:
            os.close(self.exit_fd)
            self.exit_fd = None

    def limit_lifetime(self, deadline):
        """Keep the original subscription cap across terminal recovery attempts."""
        if self.process is not None:
            self.process.limit(deadline)

    def take_snapshot(self):
        if not self._dirty:
            return None
        value = self._snapshot()
        self._dirty = False
        return value

    def poll(self, now: float | None = None) -> dict | None:
        """Sample a standalone session. Broker ingestion is event driven."""
        if self.closed:
            return None
        self.expire(self.clock() if now is None else now)
        if not self.closed:
            self.ingest(self.clock() + MAX_POLL_SECONDS)
            self.check_exit()
        return self.take_snapshot()

    sample = poll

    def _snapshot(self) -> dict:
        exited = self.check_exit()
        exit_code = self.process.returncode
        screen = self.screen
        rows = [dict(runs=screen.runs(row)) for row in range(screen.rows)]
        changed = []
        current = [(tuple(screen.cells[row]), tuple(screen.styles[row])) for row in range(screen.rows)]
        for row in range(screen.rows):
            if self._previous is None or row >= len(self._previous) or self._previous[row] != current[row]:
                # Whole changed rows keep blank clearing explicit and bounded.
                changed.extend(dict(row=row, **run) for run in rows[row]["runs"])
        self._previous = current
        self.sequence += 1
        return dict(generation=self.generation, sequence=self.sequence,
                    columns=screen.columns, rowCount=screen.rows, rows=rows,
                    changedRuns=changed, readiness="settled" if self.eof and exited else "partial",
                    exited=exited, exitCode=exit_code,
                    bytesObserved=self.total_bytes, stopReason=self.reason,
                    sourceCapabilities=dict(completeLiveFrames=False, unicode="combining-and-east-asian-width"))

    def resize(self, columns: int, rows: int) -> None:
        if self.closed:
            return
        _dimensions(columns, rows)
        if (columns, rows) == (self.screen.columns, self.screen.rows):
            return
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.screen.resize(columns, rows)
        self._previous, self._dirty = None, True

    def write(self, text: str) -> int:
        if not isinstance(text, str) or len(text.encode()) > 4096:
            raise ValueError("terminal input exceeds 4096 bytes")
        if self.closed or self.eof or self.process.poll() is not None:
            return 0
        try:
            return os.write(self.fd, text.encode())
        except BlockingIOError:
            return 0

    def action(self, action: str, payload: dict) -> None:
        if not isinstance(payload, dict):
            raise ValueError("terminal action payload must be an object")
        if action == "resize" and set(payload) == {"columns", "rows"}:
            self.resize(payload["columns"], payload["rows"])
        elif action == "input" and set(payload) == {"text"}:
            self.write(payload["text"])
        else:
            raise ValueError("unknown terminal action")

    def close(self) -> None:
        if self.closed:
            return
        before_close, self.before_close = self.before_close, None
        if before_close:
            before_close()
        if self.process is not None:
            self.process.close()
        self.closed = True
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1
        self.release_exit_watch()
        _SESSIONS.discard(self)

