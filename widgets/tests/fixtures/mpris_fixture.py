"""Private test player and runner. This fixture never emits audio."""

from __future__ import annotations

import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "org.mpris.MediaPlayer2.blox_fixture"
PATH = "/org/mpris/MediaPlayer2"
PLAYER = "org.mpris.MediaPlayer2.Player"
CONTROL = "org.blox.Fixture.Mpris"
TRACK = "/org/mpris/MediaPlayer2/track/fixture"
INTROSPECTION = """<node>
<interface name="org.mpris.MediaPlayer2">
 <method name="Raise"/><method name="Quit"/>
 <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
 <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
 <property name="DesktopEntry" type="s" access="read"/>
 <property name="SupportedUriSchemes" type="as" access="read"/><property name="SupportedMimeTypes" type="as" access="read"/>
</interface>
<interface name="org.mpris.MediaPlayer2.Player">
 <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/><method name="Stop"/><method name="Play"/>
 <method name="Seek"><arg name="Offset" type="x" direction="in"/></method>
 <method name="SetPosition"><arg name="TrackId" type="o" direction="in"/><arg name="Position" type="x" direction="in"/></method>
 <method name="OpenUri"><arg name="Uri" type="s" direction="in"/></method>
 <signal name="Seeked"><arg name="Position" type="x"/></signal>
 <property name="PlaybackStatus" type="s" access="read"/><property name="LoopStatus" type="s" access="readwrite"/>
 <property name="Rate" type="d" access="readwrite"/><property name="Shuffle" type="b" access="readwrite"/>
 <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="readwrite"/>
 <property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/>
 <property name="MaximumRate" type="d" access="read"/>
 <property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/>
 <property name="CanPlay" type="b" access="read"/><property name="CanPause" type="b" access="read"/>
 <property name="CanSeek" type="b" access="read"/><property name="CanControl" type="b" access="read"/>
</interface>
<interface name="org.blox.Fixture.Mpris"><method name="HiddenTrack"/></interface>
</node>"""


class Player:
    def __init__(self, art_one: str, art_two: str, log: Path):
        self.connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.art_one, self.art_two, self.log = art_one, art_two, log
        self.title, self.art = "Fixture first track", art_one
        self.status, self.position, self.anchor = "Paused", 12_500_000, time.monotonic()
        self.loop = GLib.MainLoop()
        self.registrations = []
        node = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION)
        for interface in node.interfaces:
            self.registrations.append(self.connection.register_object(PATH, interface, self.call, self.get, self.set))
        self.owner = Gio.bus_own_name_on_connection(self.connection, NAME, Gio.BusNameOwnerFlags.NONE,
            lambda *args: print("MPRIS_FIXTURE_READY", flush=True), lambda *args: self.loop.quit())

    def current_position(self):
        return self.position + (int((time.monotonic() - self.anchor) * 1_000_000) if self.status == "Playing" else 0)

    def metadata(self):
        return {"mpris:trackid": GLib.Variant("o", TRACK), "mpris:length": GLib.Variant("x", 120_000_000),
                "mpris:artUrl": GLib.Variant("s", self.art), "xesam:title": GLib.Variant("s", self.title),
                "xesam:artist": GLib.Variant("as", ["Fixture artist"]), "xesam:album": GLib.Variant("s", "Fixture album")}

    def get(self, connection, sender, path, interface, name):
        if interface == "org.mpris.MediaPlayer2":
            values = {"CanQuit": ("b", False), "CanRaise": ("b", False), "HasTrackList": ("b", False),
                      "Identity": ("s", "Fixture media player"), "DesktopEntry": ("s", "fixture-no-execution"),
                      "SupportedUriSchemes": ("as", ["file"]), "SupportedMimeTypes": ("as", ["audio/fixture"])}
        else:
            values = {"PlaybackStatus": ("s", self.status), "LoopStatus": ("s", "None"), "Rate": ("d", 1.0),
                      "Shuffle": ("b", False), "Metadata": ("a{sv}", self.metadata()), "Volume": ("d", 0.5),
                      "Position": ("x", self.current_position()), "MinimumRate": ("d", 1.0), "MaximumRate": ("d", 1.0),
                      **{key: ("b", True) for key in ("CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek", "CanControl")}}
        return GLib.Variant(*values[name])

    def set(self, *args):
        return True

    def changed(self, changes):
        self.connection.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                    GLib.Variant("(sa{sv}as)", (PLAYER, changes, [])))

    def seek(self, position):
        self.position, self.anchor = position, time.monotonic()
        self.connection.emit_signal(None, PATH, PLAYER, "Seeked", GLib.Variant("(x)", (position,)))

    def call(self, connection, sender, path, interface, method, parameters, invocation):
        with self.log.open("a") as stream:
            stream.write(json.dumps({"method": method, "parameters": parameters.unpack()}) + "\n")
        if method in ("PlayPause", "Pause", "Play", "Stop"):
            self.position = self.current_position()
            self.anchor = time.monotonic()
            self.status = ("Paused" if self.status == "Playing" else "Playing") if method == "PlayPause" else {"Pause": "Paused", "Play": "Playing", "Stop": "Stopped"}[method]
            self.changed({"PlaybackStatus": GLib.Variant("s", self.status)})
        elif method in ("Next", "Previous", "HiddenTrack"):
            self.title = {"Next": "Fixture next track", "Previous": "Fixture previous track", "HiddenTrack": "Fixture hidden track"}[method]
            self.art = self.art_one if method == "Previous" else self.art_two
            self.changed({"Metadata": GLib.Variant("a{sv}", self.metadata())})
            self.seek({"Next": 0, "Previous": 3_000_000, "HiddenTrack": 7_000_000}[method])
        elif method == "SetPosition":
            track, position = parameters.unpack()
            if track == TRACK:
                self.seek(position)
        elif method == "Seek":
            self.seek(self.current_position() + parameters.unpack()[0])
        invocation.return_value(GLib.Variant("()", ()))


def control(operation):
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    if operation == "seek":
        interface, method, parameters = PLAYER, "SetPosition", GLib.Variant("(ox)", (TRACK, 42_000_000))
    else:
        interface, method, parameters = CONTROL, "HiddenTrack", None
    connection.call_sync(NAME, PATH, interface, method, parameters, None, Gio.DBusCallFlags.NONE, 2000, None)


def run():
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="blox-mpris-private-") as temporary:
        directory = Path(temporary)
        environment = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "QT_QPA_PLATFORMTHEME", "QT_STYLE_OVERRIDE"):
            environment.pop(name, None)
        for name in ("XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            path = directory / name
            path.mkdir(mode=0o700)
            environment[name] = str(path)
        art_one = (root / "preview-fixtures/fixture-artwork.svg").as_uri()
        art_two_path = directory / "fixture-art-two.svg"
        art_two_path.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#89b4fa"/><text x="2" y="22" font-size="8">FIXTURE</text></svg>')
        environment.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
            QML_IMPORT_PATH=str(root / "qml"), BLOX_MPRIS_FIXTURE=str(Path(__file__).resolve()),
            BLOX_MPRIS_ART_ONE=art_one, BLOX_MPRIS_ART_TWO=art_two_path.as_uri())
        log = directory / "fixture-calls.jsonl"
        service = subprocess.Popen([sys.executable, __file__, "serve", art_one, art_two_path.as_uri(), str(log)],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            selector = selectors.DefaultSelector()
            selector.register(service.stdout, selectors.EVENT_READ)
            if not selector.select(3) or "MPRIS_FIXTURE_READY" not in service.stdout.readline():
                raise RuntimeError("Private fixture player did not acquire its test bus name")
            result = subprocess.run(["quickshell", "--path", str(Path(__file__).with_name("MprisNative.qml"))],
                env=environment, capture_output=True, text=True, timeout=18)
            output = result.stdout + result.stderr
            print(output, end="")
            if result.returncode or "MPRIS-FIXTURE-PASSED" not in output or "MPRIS-FIXTURE-FAILED" in output:
                return 1
            calls = [json.loads(line)["method"] for line in log.read_text().splitlines()]
            toggled = calls.count("PlayPause") == 2 or calls.count("Play") == 1 and calls.count("Pause") == 1
            if not toggled or not {"Next", "Previous", "SetPosition", "HiddenTrack"}.issubset(calls):
                raise RuntimeError("Expected fixture actions were not received: " + repr(calls))
            print("MPRIS-FIXTURE-CALLS " + json.dumps(calls))
            return 0
        finally:
            service.terminate()
            try:
                service.wait(timeout=2)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait(timeout=2)


if __name__ == "__main__":
    if os.environ.get("BLOX_MPRIS_PRIVATE_FIXTURE") != "1" or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise SystemExit("This fixture must run inside its private dbus-run-session test")
    if sys.argv[1] == "serve":
        Player(sys.argv[2], sys.argv[3], Path(sys.argv[4])).loop.run()
    elif sys.argv[1] == "control":
        control(sys.argv[2])
    else:
        raise SystemExit(run())
