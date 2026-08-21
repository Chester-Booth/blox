from __future__ import annotations

import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]
HELPER = REPOSITORY / "shell/scripts/widgets/terminal-frame.py"
SPEC = importlib.util.spec_from_file_location("terminal_frame", HELPER)
assert SPEC and SPEC.loader
terminal_frame = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(terminal_frame)


class AnsiScreenTests(unittest.TestCase):
    def test_cursor_motion_erase_and_styling_produce_plain_frame(self) -> None:
        screen = terminal_frame.AnsiScreen(4, 12)
        screen.feed(b"first\r\nsecond\x1b[1;1H\x1b[31mNEW\x1b[0m\x1b[2;4H\x1b[K")
        self.assertEqual("NEWst\nsec", screen.text())

    def test_clear_screen_discards_previous_frame(self) -> None:
        screen = terminal_frame.AnsiScreen(3, 10)
        screen.feed(b"old frame\x1b[2J\x1b[2;3Hnew")
        self.assertEqual("\n  new", screen.text())

    def test_background_coloured_spaces_remain_visible(self) -> None:
        screen = terminal_frame.AnsiScreen(2, 6)
        screen.feed(b"\x1b[42m   \x1b[49m ")
        rendered = screen.rich_text()
        self.assertNotIn("█", rendered)
        self.assertIn("background-color:#98971a", rendered)
        self.assertEqual(3, rendered.count("&nbsp;"))

    def test_rich_frame_preserves_ansi_colours(self) -> None:
        screen = terminal_frame.AnsiScreen(2, 8)
        screen.feed(b"\x1b[31mred\x1b[0m \x1b[48;5;25m  \x1b[0m")
        rendered = screen.rich_text()
        self.assertIn("color:#cc241d", rendered)
        self.assertIn("background-color:#005faf", rendered)
        self.assertIn("red", rendered)

    def test_reverse_index_scroll_region_does_not_leave_aquarium_trails(self) -> None:
        screen = terminal_frame.AnsiScreen(6, 8)
        screen.feed(b"top\r\nold-1\r\nold-2\r\nold-3\r\nfooter\x1b[2;4r\x1b[2;1H\x1bMnew")
        self.assertEqual("top\nnew\nold-1\nold-2\nfooter", screen.text())

    def test_cursor_save_restore_and_character_erase_replace_clock_cells(self) -> None:
        screen = terminal_frame.AnsiScreen(2, 8)
        screen.feed(b"12:08\x1b7\x1b[1;4H\x1b[2X04\x1b8!")
        self.assertEqual("12:04!", screen.text())

    def test_clock_frame_can_crop_terminal_padding(self) -> None:
        screen = terminal_frame.AnsiScreen(5, 10)
        screen.feed(b"\x1b[3;5H\x1b[42m  X\x1b[0m")
        rendered = screen.rich_text(crop=True)
        self.assertFalse(rendered.startswith("<br>"))
        self.assertEqual(3, rendered.count("&nbsp;") + rendered.count("X"))

    def test_clock_block_frame_is_plain_text_and_crops_terminal_padding(self) -> None:
        screen = terminal_frame.AnsiScreen(5, 12)
        screen.feed(b"\x1b[3;5H\x1b[42m  \x1b[49m  \x1b[42m  \x1b[0m\x1b[4;5Hdate")
        rendered = screen.block_text(crop=True)
        self.assertEqual("██  ██\ndate", rendered)
        self.assertNotIn("<span", rendered)

    def test_clock_block_frame_fully_replaces_changed_background_cells(self) -> None:
        screen = terminal_frame.AnsiScreen(2, 8)
        screen.feed(b"\x1b[42m      \x1b[49m")
        self.assertEqual("██████", screen.block_text(crop=True))
        screen.feed(b"\r\x1b[42m  \x1b[49m    ")
        self.assertEqual("██", screen.block_text(crop=True))


class TerminalWidgetSafetyTests(unittest.TestCase):
    def test_only_known_presets_can_be_resolved(self) -> None:
        self.assertEqual(("tty-clock",), terminal_frame.command_for("clock"))
        self.assertEqual(("tty-clock", "-s"), terminal_frame.command_for("clock", "tty-clock -s"))
        self.assertEqual(("tty-clock", "-s"), terminal_frame.command_for("clock", "tty-clock -c -s"))
        with self.assertRaisesRegex(ValueError, "must run tty-clock"):
            terminal_frame.command_for("clock", "sh -c 'tty-clock; touch /tmp/nope'")
        with self.assertRaisesRegex(ValueError, "unsupported"):
            terminal_frame.command_for("custom; rm -rf -- /tmp/example")

    def test_capture_uses_argument_vector_and_bounded_process_group(self) -> None:
        fake_process = mock.Mock(pid=1234)
        fake_process.poll.return_value = 0
        with mock.patch.object(terminal_frame.pty, "openpty", return_value=(10, 11)), \
             mock.patch.object(terminal_frame.termios, "tcsetwinsize"), \
             mock.patch.object(terminal_frame.os, "close"), \
             mock.patch.object(terminal_frame, "spawn_terminal", return_value=fake_process) as spawn, \
             mock.patch.object(terminal_frame.select, "select", return_value=([], [], [])):
            terminal_frame.capture(("tty-clock", "-c"), 20, 60, 0.0001, 100)
        self.assertEqual(("tty-clock", "-c"), spawn.call_args.args[0])

    def test_terminal_children_receive_a_parent_death_signal(self) -> None:
        fake_process = mock.Mock()
        with mock.patch.object(terminal_frame.os, "getpid", return_value=123), \
             mock.patch.object(terminal_frame.subprocess, "Popen", return_value=fake_process) as popen:
            self.assertIs(fake_process, terminal_frame.spawn_terminal(("cava",), 11, {}))
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertIsNotNone(popen.call_args.kwargs["preexec_fn"])

    def test_cli_arms_its_own_parent_death_signal(self) -> None:
        source = HELPER.read_text(encoding="utf-8")
        entrypoint = source.split('if __name__ == "__main__":', 1)[1]
        self.assertIn("terminate_with_parent(os.getppid())", entrypoint)

    def test_already_orphaned_process_terminates_immediately(self) -> None:
        with mock.patch.object(terminal_frame.os, "getpid", return_value=456), \
             mock.patch.object(terminal_frame.os, "kill") as kill:
            terminal_frame.terminate_with_parent(1)
        kill.assert_called_once_with(456, terminal_frame.signal.SIGTERM)

    def test_missing_dependency_is_a_user_facing_frame(self) -> None:
        completed = subprocess.run([str(HELPER), "clock", "--duration-ms", "50"], check=True, text=True, capture_output=True)
        self.assertTrue(completed.stdout.strip())

    def test_stream_emits_distinct_json_frames(self) -> None:
        command = (
            "for frame in one two three; do "
            "printf '\\033[2J%s' \"$frame\"; sleep 0.06; done"
        )
        with mock.patch.object(terminal_frame, "command_for", return_value=("sh", "-c", command)):
            frames: list[str] = []
            with mock.patch("builtins.print", side_effect=lambda value, **_kwargs: frames.append(json.loads(value))):
                terminal_frame.stream(("sh", "-c", command), 4, 20, 0.05, 1024)
        self.assertGreaterEqual(len(set(frames)), 2)

    def test_plain_stream_avoids_rich_text_markup(self) -> None:
        command = "printf '\\033[31mred\\033[0m'; sleep 0.06"
        frames: list[str] = []
        with mock.patch("builtins.print", side_effect=lambda value, **_kwargs: frames.append(json.loads(value))):
            terminal_frame.stream(("sh", "-c", command), 4, 20, 0.05, 1024, plain=True)
        self.assertIn("red", frames)
        self.assertTrue(all("<span" not in frame for frame in frames))

    def test_clock_stream_emits_plain_block_frames(self) -> None:
        command = "printf '\\033[42m  \\033[49m'; sleep 0.06; printf '\\r\\033[42m    \\033[49m'"
        frames: list[str] = []
        with mock.patch("builtins.print", side_effect=lambda value, **_kwargs: frames.append(json.loads(value))):
            terminal_frame.stream(("sh", "-c", command), 4, 20, 0.05, 1024, crop=True, block=True)
        self.assertIn("██", frames)
        self.assertIn("████", frames)
        self.assertTrue(all("<" not in frame for frame in frames))

    def test_clock_cli_streams_complete_snapshots(self) -> None:
        with mock.patch.object(terminal_frame, "command_for", return_value=("tty-clock", "-s")), \
             mock.patch.object(terminal_frame, "snapshot_stream", return_value=0) as snapshot_stream:
            with mock.patch("sys.argv", [str(HELPER), "clock", "--stream", "--frame-ms", "500"]):
                self.assertEqual(0, terminal_frame.main())
        self.assertEqual(("tty-clock", "-s"), snapshot_stream.call_args.args[0])
        self.assertEqual(0.5, snapshot_stream.call_args.args[3])

    def test_stream_accepts_a_longer_atomic_settle_window(self) -> None:
        command = "printf X; sleep 0.03; printf Y; sleep 0.12"
        frames: list[str] = []
        with mock.patch("builtins.print", side_effect=lambda value, **_kwargs: frames.append(json.loads(value))):
            terminal_frame.stream(("sh", "-c", command), 4, 20, 0.05, 1024, plain=True, settle_time=0.1)
        self.assertNotIn("X", frames)
        self.assertIn("XY", frames)

    def test_clock_snapshot_stream_uses_fresh_complete_screens(self) -> None:
        first = terminal_frame.AnsiScreen(2, 8)
        first.feed(b"\x1b[42m  \x1b[49m")
        second = terminal_frame.AnsiScreen(2, 8)
        second.feed(b"\x1b[42m    \x1b[49m")
        frames: list[str] = []
        with mock.patch.object(terminal_frame, "capture_screen", side_effect=[first, second]) as capture_screen, \
             mock.patch("builtins.print", side_effect=lambda value, **_kwargs: frames.append(json.loads(value))):
            terminal_frame.snapshot_stream(("tty-clock", "-s"), 4, 20, frame_interval=0, max_frames=2)
        self.assertEqual(["██", "████"], frames)
        self.assertEqual(2, capture_screen.call_count)

    def test_stream_waits_for_ncurses_redraw_to_settle(self) -> None:
        command = (
            "printf '\\033[2JOLD'; sleep 0.08; "
            "printf '\\033[2JX'; sleep 0.015; printf 'YZ'; sleep 0.08"
        )
        frames: list[str] = []
        with mock.patch("builtins.print", side_effect=lambda value, **_kwargs: frames.append(json.loads(value))):
            terminal_frame.stream(("sh", "-c", command), 4, 20, 0.05, 1024, crop=True, block=True)
        self.assertIn("OLD", frames)
        self.assertIn("XYZ", frames)
        self.assertNotIn("X", frames)


if __name__ == "__main__":
    unittest.main()
