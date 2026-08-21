# Blox Quickshell

Quickshell configuration for the configurable bar, popouts and desktop widgets.

This config is independent from the old Waybar setup. Runtime helper scripts now
live under neutral backend directories in `scripts/`, while the old top-level
Waybar and Eww configs are left stale outside this live path.

Run with:

```sh
quickshell -c blox
```

Private environment values are read from:

```sh
~/.config/quickshell/blox/env
```

Create it from the tracked template:

```sh
cp ~/.config/quickshell/blox/env.example ~/.config/quickshell/blox/env
```

`EXPENSES_API_BASE_URL` is optional. When set, `scripts/todo/generated-refresh.sh`
uses it to refresh expenses-generated todo markdown files.

Layout:

- `shell.qml` - Quickshell entrypoint.
- `modules/` - top-level shell surfaces, including the bar, desktop widgets and IPC-opened theme picker.
- `shared/` - theme and reusable UI pieces.
- `services/` - status polling, persisted UI state, action execution, notification,
  workspace, and derived-content controllers.
- `popouts/` - click-open panel surfaces.
- `scripts/status/` - JSON status producers for the bar and popouts.
- `scripts/{calendar,display,gpu,network,power,theme,todo,update,workspaces}/` - action and domain backends.
- `scripts/widgets/` - desktop-widget rendering, state and action helpers.
- `scripts/contracts/status.json` - expected JSON contracts for status-producing scripts.

Validate script output contracts with:

```sh
~/.config/quickshell/blox/scripts/validate-status.py
```

## Calendar writes

The calendar reads Google calendars through the existing gcalcli sign-in. On first use, only the primary writable calendar can be changed.

To allow another writable calendar, create `~/.config/quickshell/blox/calendar.json`:

```json
{
  "writable_calendar_ids": [
    "primary@example.com",
    "another-calendar-id@group.calendar.google.com"
  ]
}
```

Run the adapter doctor to check the installed gcalcli version, sign-in and cache without changing calendar data:

```sh
~/.config/quickshell/blox/scripts/calendar/calendar_adapter.py doctor
```

The contracts keep script changes honest: each producer must emit valid JSON
with the fields and types the QML expects.
