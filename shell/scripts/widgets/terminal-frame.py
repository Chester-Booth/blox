#!/usr/bin/env python3
"""Capture one bounded plain-text frame from a supported terminal widget."""

from __future__ import annotations

import argparse
import ctypes
import html
import json
import os
import pty
import re
import select
import signal
import shlex
import struct
import subprocess
import termios
import time


PRESET_COMMANDS: dict[str, tuple[str, ...]] = {
    "music": ("cava",),
    "clock": ("tty-clock",),
    "aquarium": ("asciiquarium",),
    "pipes": ("pipes.sh",),
    "tree": ("cbonsai", "-l"),
    "matrix": ("unimatrix",),
    "train": ("sl",),
}
CSI_FINAL = re.compile(r"[@-~]")
PR_SET_PDEATHSIG = 1


def terminate_with_parent(parent_pid: int) -> None:
    """Ensure a terminal child cannot survive its renderer being killed."""
    if parent_pid <= 1:
        os.kill(os.getpid(), signal.SIGTERM)
        return
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_PDEATHSIG) failed")
    if os.getppid() != parent_pid:
        os.kill(os.getpid(), signal.SIGTERM)


def spawn_terminal(command: tuple[str, ...], slave: int, environment: dict[str, str]) -> subprocess.Popen[bytes]:
    parent_pid = os.getpid()
    return subprocess.Popen(
        command,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
        start_new_session=True,
        close_fds=True,
        preexec_fn=lambda: terminate_with_parent(parent_pid),
    )


class AnsiScreen:
    """Small ANSI/VT screen model sufficient for common terminal toys."""

    def __init__(self, rows: int, columns: int) -> None:
        self.rows = rows
        self.columns = columns
        self.cells = [[" "] * columns for _ in range(rows)]
        self.styles = [[(None, None, False)] * columns for _ in range(rows)]
        self.row = 0
        self.column = 0
        self.state = "text"
        self.csi = ""
        self.background = False
        self.foreground_colour: str | None = None
        self.background_colour: str | None = None
        self.bold = False
        self.scroll_top = 0
        self.scroll_bottom = rows - 1
        self.saved_cursor = (0, 0)

    def _blank_row(self) -> tuple[list[str], list[tuple[str | None, str | None, bool]]]:
        return ([" "] * self.columns, [(None, None, False)] * self.columns)

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
        for char in data.decode("utf-8", errors="replace"):
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
            elif char == "\n":
                self._index()
            elif char == "\b":
                self.column = max(0, self.column - 1)
            elif char == "\t":
                self.column = min(self.columns - 1, (self.column // 8 + 1) * 8)
            elif char >= " " and char != "\x7f":
                self.cells[self.row][self.column] = char
                self.styles[self.row][self.column] = (self.foreground_colour, self.background_colour, self.bold)
                self.column += 1
                if self.column >= self.columns:
                    self.column = 0
                    self.row = min(self.rows - 1, self.row + 1)

    @staticmethod
    def _parameters(raw: str) -> list[int]:
        raw = raw.lstrip("?<=>")
        return [int(value) if value.isdigit() else 0 for value in raw.split(";")]

    def _csi(self, raw: str, final: str) -> None:
        values = self._parameters(raw)
        amount = values[0] or 1
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
            if mode in (2, 3):
                self.cells = [[" "] * self.columns for _ in range(self.rows)]
                self.styles = [[(None, None, False)] * self.columns for _ in range(self.rows)]
                self.row = self.column = 0
            elif mode == 0:
                self._erase_to_end()
        elif final == "K":
            mode = values[0]
            start, end = (0, self.columns) if mode == 2 else ((0, self.column + 1) if mode == 1 else (self.column, self.columns))
            self.cells[self.row][start:end] = [" "] * (end - start)
            self.styles[self.row][start:end] = [(None, None, False)] * (end - start)
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
            self.styles[self.row].extend([(None, None, False)] * count)
        elif final == "@":
            count = min(amount, self.columns - self.column)
            self.cells[self.row][self.column:self.column] = [" "] * count
            self.styles[self.row][self.column:self.column] = [(None, None, False)] * count
            del self.cells[self.row][self.columns:]
            del self.styles[self.row][self.columns:]
        elif final == "X":
            end = min(self.columns, self.column + amount)
            self.cells[self.row][self.column:end] = [" "] * (end - self.column)
            self.styles[self.row][self.column:end] = [(None, None, False)] * (end - self.column)
        elif final == "m":
            # Preserve shapes drawn with coloured terminal backgrounds (notably
            # tty-clock) even though the QML widget supplies the final colour.
            if not values or 0 in values or 49 in values:
                self.background = False
            self._sgr(values)
            if any(40 <= value <= 47 or 100 <= value <= 107 or value == 48 for value in values):
                self.background = True
        # Styling, cursor visibility and alternate-screen controls need no action.

    def _erase_to_end(self) -> None:
        self.cells[self.row][self.column:] = [" "] * (self.columns - self.column)
        self.styles[self.row][self.column:] = [(None, None, False)] * (self.columns - self.column)
        for row in range(self.row + 1, self.rows):
            self.cells[row] = [" "] * self.columns
            self.styles[row] = [(None, None, False)] * self.columns

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
                self.bold = False
            elif value == 1:
                self.bold = True
            elif value == 22:
                self.bold = False
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

    def text(self) -> str:
        lines = ["".join(row).rstrip() for row in self.cells]
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines)

    def rich_text(self, crop: bool = False) -> str:
        occupied = [
            (row, column)
            for row in range(self.rows)
            for column in range(self.columns)
            if self.cells[row][column] != " " or self.styles[row][column][1] is not None
        ]
        first_row = min((position[0] for position in occupied), default=0) if crop else 0
        first_column = min((position[1] for position in occupied), default=0) if crop else 0
        last_row = max(
            (
                row
                for row, cells in enumerate(self.cells)
                if "".join(cells).rstrip()
                or any(background is not None for _foreground, background, _bold in self.styles[row])
            ),
            default=-1,
        )
        lines: list[str] = []
        for row in range(first_row, last_row + 1):
            last_column = max(
                (
                    column
                    for column, char in enumerate(self.cells[row])
                    if char != " " or self.styles[row][column][1] is not None
                ),
                default=-1,
            )
            pieces: list[str] = []
            active = None
            for column in range(first_column, last_column + 1):
                style = self.styles[row][column]
                if style != active:
                    if active is not None:
                        pieces.append("</span>")
                    foreground, background, bold = style
                    css = []
                    if foreground:
                        css.append(f"color:{foreground}")
                    if background:
                        css.append(f"background-color:{background}")
                    if bold:
                        css.append("font-weight:bold")
                    pieces.append(f'<span style="{";".join(css)}">')
                    active = style
                pieces.append(html.escape(self.cells[row][column]).replace(" ", "&nbsp;"))
            if active is not None:
                pieces.append("</span>")
            lines.append("".join(pieces))
        return "<br>".join(lines)

    def block_text(self, crop: bool = False) -> str:
        """Render terminal background cells as stable foreground block glyphs.

        Qt's rich-text renderer can retain stale background-painted spaces when
        a rapidly changing span becomes shorter.  That is particularly visible
        with tty-clock, whose digits are made entirely from background-coloured
        spaces.  Converting those cells to ordinary glyphs gives Qt a complete
        plain-text frame to replace on every tick.
        """
        occupied = [
            (row, column)
            for row in range(self.rows)
            for column in range(self.columns)
            if self.cells[row][column] != " " or self.styles[row][column][1] is not None
        ]
        if not occupied:
            return ""
        first_row = min(row for row, _column in occupied) if crop else 0
        first_column = min(column for _row, column in occupied) if crop else 0
        last_row = max(row for row, _column in occupied)
        last_column = max(column for _row, column in occupied)
        lines = []
        for row in range(first_row, last_row + 1):
            line = "".join(
                "█" if self.styles[row][column][1] is not None else self.cells[row][column]
                for column in range(first_column, last_column + 1)
            )
            lines.append(line.rstrip())
        return "\n".join(lines)


def command_for(preset: str, requested: str = "") -> tuple[str, ...]:
    try:
        default = PRESET_COMMANDS[preset]
    except KeyError as error:
        raise ValueError(f"unsupported terminal widget preset: {preset}") from error
    if not requested:
        return default
    command = tuple(shlex.split(requested))
    if not command or os.path.basename(command[0]) != default[0]:
        raise ValueError(f"{preset} widgets must run {default[0]}")
    if preset == "clock":
        # The widget owns its geometry, so tty-clock must draw from the PTY's
        # top-left instead of centring and adding terminal-sized padding.
        command = tuple(argument for argument in command if argument != "-c")
    if len(command) > 24 or any(len(argument) > 256 or "\x00" in argument for argument in command):
        raise ValueError("terminal widget command options exceed the safety limits")
    return command


def capture_screen(command: tuple[str, ...], rows: int, columns: int, duration: float, max_bytes: int) -> AnsiScreen:
    master, slave = pty.openpty()
    termios.tcsetwinsize(slave, (rows, columns))
    environment = {**os.environ, "TERM": "xterm-256color", "COLUMNS": str(columns), "LINES": str(rows)}
    process = spawn_terminal(command, slave, environment)
    os.close(slave)
    screen = AnsiScreen(rows, columns)
    deadline = time.monotonic() + duration
    received = 0
    try:
        while time.monotonic() < deadline and received < max_bytes:
            ready, _, _ = select.select([master], [], [], min(0.05, max(0, deadline - time.monotonic())))
            if not ready:
                if process.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, min(8192, max_bytes - received))
            except OSError:
                break
            if not chunk:
                break
            received += len(chunk)
            screen.feed(chunk)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=0.2)
        os.close(master)
    return screen


def capture(command: tuple[str, ...], rows: int, columns: int, duration: float, max_bytes: int) -> str:
    return capture_screen(command, rows, columns, duration, max_bytes).text()


def snapshot_stream(
    command: tuple[str, ...],
    rows: int,
    columns: int,
    frame_interval: float = 0.5,
    max_frames: int | None = None,
) -> int:
    """Emit complete clock snapshots from short-lived tty-clock processes.

    tty-clock updates its persistent ncurses screen through several partial
    writes. A fresh process always paints a complete initial screen, so taking
    independent snapshots prevents an intermediate digit from reaching QML.
    """
    previous = ""
    attempts = 0
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def stop_stream(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop_stream)
    try:
        while max_frames is None or attempts < max_frames:
            started = time.monotonic()
            screen = capture_screen(command, rows, columns, 0.12, 256 * 1024)
            rendered = screen.block_text(crop=True)
            if rendered and rendered != previous:
                print(json.dumps(rendered, ensure_ascii=False), flush=True)
                previous = rendered
            attempts += 1
            remaining = frame_interval - (time.monotonic() - started)
            if remaining > 0 and (max_frames is None or attempts < max_frames):
                time.sleep(remaining)
        return 0
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)


def stream(
    command: tuple[str, ...],
    rows: int,
    columns: int,
    frame_interval: float,
    max_bytes_per_frame: int,
    crop: bool = False,
    block: bool = False,
    plain: bool = False,
    settle_time: float | None = None,
) -> int:
    """Run a terminal program once and emit newline-delimited rich-text frames."""
    master, slave = pty.openpty()
    termios.tcsetwinsize(slave, (rows, columns))
    environment = {**os.environ, "TERM": "xterm-256color", "COLUMNS": str(columns), "LINES": str(rows)}
    process = spawn_terminal(command, slave, environment)
    os.close(slave)
    screen = AnsiScreen(rows, columns)
    next_frame = time.monotonic()
    last_input = next_frame
    settle_interval = settle_time if settle_time is not None else min(0.03, frame_interval / 2)
    publish_deadline = next_frame + settle_interval
    received = 0
    previous = ""
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def stop_stream(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop_stream)
    try:
        while process.poll() is None:
            now = time.monotonic()
            if now < next_frame:
                wait_until = next_frame
            else:
                wait_until = min(publish_deadline, last_input + settle_interval)
            ready, _, _ = select.select([master], [], [], min(0.05, max(0, wait_until - now)))
            if ready:
                try:
                    chunk = os.read(master, min(8192, max_bytes_per_frame - received))
                except OSError:
                    break
                if not chunk:
                    break
                received += len(chunk)
                screen.feed(chunk)
                last_input = time.monotonic()
            now = time.monotonic()
            if now >= next_frame and (now - last_input >= settle_interval or now >= publish_deadline):
                rendered = screen.block_text(crop=crop) if block else screen.text() if plain else screen.rich_text(crop=crop)
                if rendered and rendered != previous:
                    print(json.dumps(rendered, ensure_ascii=False), flush=True)
                    previous = rendered
                next_frame = max(next_frame + frame_interval, now)
                publish_deadline = next_frame + settle_interval
                received = 0
        rendered = screen.block_text(crop=crop) if block else screen.text() if plain else screen.rich_text(crop=crop)
        if rendered and rendered != previous:
            print(json.dumps(rendered, ensure_ascii=False), flush=True)
        return process.wait()
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=0.2)
        os.close(master)
        signal.signal(signal.SIGTERM, previous_sigterm)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("preset", choices=tuple(PRESET_COMMANDS))
    parser.add_argument("--rows", type=int, default=20)
    parser.add_argument("--columns", type=int, default=60)
    parser.add_argument("--duration-ms", type=int, default=350)
    parser.add_argument("--stream", action="store_true")
    parser.add_argument("--plain", action="store_true")
    parser.add_argument("--frame-ms", type=int, default=100)
    parser.add_argument("--settle-ms", type=int, default=0)
    parser.add_argument("--command", default="")
    args = parser.parse_args()
    rows = max(4, min(80, args.rows))
    columns = max(10, min(200, args.columns))
    duration = max(0.05, min(1.5, args.duration_ms / 1000))
    try:
        command = command_for(args.preset, args.command)
        if args.stream:
            if args.preset == "clock":
                return snapshot_stream(
                    command,
                    rows,
                    columns,
                    max(0.5, min(1.0, args.frame_ms / 1000)),
                )
            return stream(
                command,
                rows,
                columns,
                max(0.01, min(1.0, args.frame_ms / 1000)),
                256 * 1024,
                crop=False,
                block=False,
                plain=args.plain,
                settle_time=max(0.001, min(0.25, args.settle_ms / 1000)) if args.settle_ms > 0 else None,
            )
        if args.preset == "clock":
            rendered = capture_screen(command, rows, columns, duration, 256 * 1024).block_text(crop=True)
        else:
            rendered = capture(command, rows, columns, duration, 256 * 1024)
    except FileNotFoundError:
        print(f"{PRESET_COMMANDS[args.preset][0]} is not installed")
        return 0
    except ValueError as error:
        print(str(error))
        return 2
    print(rendered)
    return 0


if __name__ == "__main__":
    terminate_with_parent(os.getppid())
    raise SystemExit(main())
