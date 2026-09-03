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
bloxctl doctor [--json]        # local install health, redacted by default
bloxctl lifecycle update       # new generation plus recorded migrations
bloxctl lifecycle rollback     # back to the previous generation
bloxctl lifecycle uninstall    # remove owned paths, keep user data
```

`settings` and `theme` groups are reserved for later releases and return a
typed unavailable result today.

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
