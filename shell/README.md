# Blox Quickshell

Quickshell configuration for the configurable bar, popouts and desktop widgets.

Runtime helper scripts live in `scripts/`.

Run with:

```sh
quickshell --path "${BLOX_PREFIX:-$HOME/.local}/share/blox/shell"
```

The calendar update service reads optional private environment values from:

```sh
~/.config/blox/env
```

Create it from the tracked template:

```sh
mkdir -p ~/.config/blox
cp "${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/env.example" ~/.config/blox/env
```

`EXPENSES_API_BASE_URL` is optional. When set, `scripts/todo/generated-refresh.sh`
uses it to refresh expenses-generated todo markdown files.

Layout:

- `shell.qml` - Quickshell entrypoint.
- `modules/` - top-level shell surfaces, including the bar, desktop widgets and Settings application.
- `shared/` - theme and reusable UI pieces.
- `services/` - native provider state, status polling, persisted UI state, action execution, notification,
  workspace, and derived-content controllers.
- `popouts/` - click-open panel surfaces.
- `scripts/status/` - JSON status producers for the bar and popouts that do not
  have a native Quickshell owner. Network and Bluetooth use native providers in
  `services/`.
- `scripts/graphicsctl.py` - typed Hyprland refresh, current-boot GPU inventory, non-waking dGPU client preflight and a guarded optional adapter for the archived `supergfxctl` 5.2.7 release.
- `status/vendor-performance.sh` distinguishes the shared ASUS platform profile from optional independent fan curves. The popout prefers the generic power-profile owner and uses the vendor profile only as a fallback.
- `scripts/{calendar,display,network,power,theme,todo,update,workspaces}/` - action and domain backends.
- `scripts/widgets/` - calendar, to-do and workspace status helpers.
- `scripts/contracts/status.json` - expected JSON contracts for status-producing scripts.

Validate script output contracts with:

```sh
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/validate-status.py"
```

## Calendar writes

The calendar reads Google calendars through the existing gcalcli sign-in. On first use, only the primary writable calendar can be changed.

To allow another writable calendar, create `~/.config/blox/calendar.json`:

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
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/calendar/calendar_adapter.py" doctor
```

The contracts keep script changes honest: each producer must emit valid JSON
with the fields and types the QML expects.

## Bar panels over IPC

Open a bar panel with keyboard focus, close it, or inspect the current panel
state through the `bar-panel` IPC target:

```sh
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" bar-panel open calendar
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" bar-panel state
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" bar-panel close
```

`open` accepts `power`, `system`, `audio`, `network`, `bluetooth`,
`brightness`, `notifications`, `todo`, `calendar`, `updates`, `privacy`, and
`caffeine`. An unknown section returns an `invalid-panel` result and leaves the
current panel alone. Panels opened by pointer hover keep their existing
no-focus behaviour. Use the `open` command in your own compositor key binding
if you want a keyboard shortcut. Blox does not assign a default key.

## Desktop widgets over IPC

The `widget-edit` target can focus a configured widget, inspect its edit state,
or open, save and close the widget editor:

```sh
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" widget-edit focus widget-id
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" widget-edit status
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" widget-edit open
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" widget-edit save
"${BLOX_PREFIX:-$HOME/.local}/share/blox/shell/scripts/ipc.sh" widget-edit close
```

`focus` takes the stable ID of an enabled, visible interactive widget. It
returns `focused`, `unavailable`, or `busy` while a previous focus restore is
running. The shell routes keyboard focus to one visible output. Native views
handle their own controls. Escape releases focus and restores the captured
application when it still exists. Clicking outside releases focus without
restoring the previous application. Blox assigns no default focus shortcut.

`status` returns the current edit state as JSON with `active` and `items`
fields. The other calls open the editor, save its edits or close it without
saving.
