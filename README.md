# Blox

A polished Quickshell desktop shell for Arch Linux and Hyprland. Blox provides
a bar with status popouts, a launcher, notifications, an OSD, desktop widgets,
and one theme model that drives every surface.

## Layout

- `shell/` — the Quickshell shell source, loaded as the stable `blox` identity.
- `themes/` — schema, versioned defaults, built-in themes and the theme library.
- `bin/` — `bloxctl` (shell control) and `themectl` (theme system command).
- `packaging/` — installer, lifecycle commands, unit templates and migrations.
- `tests/` — focused contract, CLI, launcher and lifecycle tests.

## Install

```sh
./bin/bloxctl lifecycle install --prefix "$HOME/.local"
```

The installer is unprivileged, idempotent, supports `--dry-run`, reports
conflicts before overwriting anything, and keeps pre-image backups under
`$XDG_STATE_HOME/blox/backups/`. It checks required tools and fonts and
reports missing ones; it never installs packages.

## Control

```sh
bloxctl status --json          # typed status through the running shell
bloxctl audio set-volume 50 --json
bloxctl audio toggle-mute --json
bloxctl audio set-mic muted --json
bloxctl display set-refresh eDP-1 144 --json
bloxctl gpu set-mode hybrid --json
bloxctl doctor [--json]        # local install health, redacted by default
bloxctl lifecycle update       # new generation plus recorded migrations
bloxctl lifecycle rollback     # back to the previous generation
bloxctl lifecycle uninstall    # remove owned paths, keep user data
```

`settings` and `theme` groups are reserved for later releases and return a
typed unavailable result today.

Refresh choices come from each active Hyprland monitor at its current
resolution. GPU mode needs both integrated and discrete graphics plus
`supergfxctl`. Blox has a guarded adapter for the last upstream release,
5.2.7, but treats the archived project as an optional controller rather than a
package dependency. It never installs or starts a switcher and rejects GPU
control while a competing one is active. `switcheroo-control` may select the
discrete GPU for one application; it does not own system GPU modes. Read-only
current-boot discovery keeps a powered-off display device in the hardware
inventory after it disappears from DRM and PCI. Blox confirms every popout GPU
switch that will log out. Before Integrated mode, it also checks which
current-user processes hold discrete GPU device nodes and lists them in the
confirmation. The GPU tray item can hide in any controller-supported mode and
defaults to Hide in Hybrid.

The performance popout prefers `power-profiles-daemon` as the single owner of
the shared platform profile, then falls back to a vendor profile provider when
the generic service is unavailable. A separate fan-curves control appears only
when the vendor backend proves that independent curves can be read and changed.

## Paths

Package data lives under `<prefix>/share/blox/`. User config, personal
overrides, imported content, generated state, cache and runtime files follow
the XDG ownership rules in `packaging/layout.py`. Blox never writes outside
its owned roots and never needs root privileges.

## Development

```sh
make check   # full local suite
make ci      # the same suite plus hygiene gates
```

## Licence

MIT. See `LICENSE`.
