#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

import gi


def rgba(value: object) -> str:
    return value.to_string() if value is not None else ""


def probe_gtk3() -> dict[str, object]:
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk

    Gtk.init([])
    window = Gtk.Window(title="Blox GTK 3 probe")
    button = Gtk.Button(label="Probe")
    button.get_style_context().add_class("blox-probe")
    window.add(button)
    window.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration_do(False)
    context = button.get_style_context()
    found, named = context.lookup_color("blox_probe")
    settings = Gtk.Settings.get_default()
    result = {
        "toolkit": "gtk3",
        "theme": settings.get_property("gtk-theme-name"),
        "font": settings.get_property("gtk-font-name"),
        "prefer_dark": settings.get_property("gtk-application-prefer-dark-theme"),
        "named_colour_found": found,
        "named_colour": rgba(named),
        "button_foreground": rgba(context.get_color(Gtk.StateFlags.NORMAL)),
    }
    window.destroy()
    return result


def probe_gtk4(adwaita: bool) -> dict[str, object]:
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk

    if adwaita:
        gi.require_version("Adw", "1")
        from gi.repository import Adw

        Adw.init()
        window = Adw.Window(title="Blox Libadwaita probe")
    else:
        Gtk.init()
        window = Gtk.Window(title="Blox GTK 4 probe")
    button = Gtk.Button(label="Probe")
    button.add_css_class("blox-probe")
    if adwaita:
        window.set_content(button)
    else:
        window.set_child(button)
    window.present()
    context = button.get_style_context()
    found, named = context.lookup_color("blox_probe")
    settings = Gtk.Settings.get_default()
    result = {
        "toolkit": "libadwaita" if adwaita else "gtk4",
        "theme": settings.get_property("gtk-theme-name"),
        "font": settings.get_property("gtk-font-name"),
        "prefer_dark": settings.get_property("gtk-application-prefer-dark-theme"),
        "named_colour_found": found,
        "named_colour": rgba(named),
        "button_foreground": rgba(context.get_color()),
    }
    if adwaita:
        result["adwaita_dark"] = Adw.StyleManager.get_default().get_dark()
    window.destroy()
    return result


def validate_css(toolkit: str, path: Path) -> dict[str, object]:
    version = "3.0" if toolkit == "gtk3" else "4.0"
    gi.require_version("Gtk", version)
    from gi.repository import Gtk

    provider = Gtk.CssProvider()
    errors: list[str] = []
    try:
        provider.connect("parsing-error", lambda _provider, _section, error: errors.append(str(error)))
    except TypeError:
        pass
    provider.load_from_path(str(path))
    return {"toolkit": toolkit, "css": str(path), "errors": errors}


def visual_probe(toolkit: str, seconds: int) -> None:
    version = "3.0" if toolkit == "gtk3" else "4.0"
    gi.require_version("Gtk", version)
    from gi.repository import GLib, Gtk

    adwaita = toolkit == "libadwaita"
    if adwaita:
        gi.require_version("Adw", "1")
        from gi.repository import Adw

        Adw.init()
        window = Adw.Window(title="Blox Libadwaita visual probe")
    else:
        Gtk.init([]) if toolkit == "gtk3" else Gtk.init()
        window = Gtk.Window(title=f"Blox GTK {version[0]} visual probe")
    window.set_default_size(520, 420)
    grid = Gtk.Grid(column_spacing=12, row_spacing=12, margin_top=24, margin_bottom=24, margin_start=24, margin_end=24)
    controls = (
        Gtk.Label(label="Generated semantic GTK controls"),
        Gtk.Entry(text="Editable text"),
        Gtk.Button(label="Primary action"),
        Gtk.CheckButton(label="Selected option"),
        Gtk.Switch(active=True),
        Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1),
        Gtk.ProgressBar(fraction=0.68, text="68%", show_text=True),
    )
    controls[3].set_active(True)
    controls[5].set_value(62)
    for row, control in enumerate(controls):
        control.set_hexpand(True)
        grid.attach(control, 0, row, 1, 1)
    if toolkit == "gtk3":
        window.add(grid)
        window.show_all()
        GLib.timeout_add_seconds(seconds, Gtk.main_quit)
        Gtk.main()
    else:
        if adwaita:
            window.set_content(grid)
        else:
            window.set_child(grid)
        window.present()
        loop = GLib.MainLoop()
        GLib.timeout_add_seconds(seconds, loop.quit)
        loop.run()
    window.destroy()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("toolkit", choices=("gtk3", "gtk4", "libadwaita"))
    parser.add_argument("--css", type=Path)
    parser.add_argument("--hold", type=int, default=0)
    args = parser.parse_args()
    if args.hold > 0:
        visual_probe(args.toolkit, args.hold)
        return 0
    if args.css:
        result = validate_css(args.toolkit, args.css)
    elif args.toolkit == "gtk3":
        result = probe_gtk3()
    else:
        result = probe_gtk4(args.toolkit == "libadwaita")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
