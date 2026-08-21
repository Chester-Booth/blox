#!/usr/bin/env python3
"""Resolve icon theme names in a fresh GTK process."""

import json
import sys

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")

from gi.repository import Gdk, Gtk  # noqa: E402


def resolve_icons(names, theme):
    resolved = {}
    for name in dict.fromkeys(names):
        if not name or not theme.has_icon(name):
            continue

        icon = theme.lookup_icon(
            name,
            [],
            32,
            1,
            Gtk.TextDirection.NONE,
            Gtk.IconLookupFlags.FORCE_REGULAR,
        )
        icon_file = icon.get_file() if icon else None
        path = icon_file.get_path() if icon_file else None
        if path:
            resolved[name] = path

    return resolved


def main():
    display = Gdk.Display.get_default()
    if display is None:
        print("{}")
        return 1

    theme = Gtk.IconTheme.get_for_display(display)
    print(json.dumps(resolve_icons(sys.argv[1:], theme), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
