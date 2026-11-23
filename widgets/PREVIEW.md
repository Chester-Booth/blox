# Source catalogue preview

Open the standalone preview from the repository root:

```sh
./widgets/run-preview.sh
```

It needs Python with PySide6. The picker contains all nine native kinds, their available styles and two trusted QML examples. Each item uses the actual `WidgetHost`, `WidgetTheme` and view files under `widgets/qml`. Profiles come from `default_widget()` and pass the shared profile validator.

The preview reads `~/.local/share/blox-user/themes/blox-panel.json`, respecting `XDG_DATA_HOME`. It injects the theme palette, UI and monospace fonts, roundness and density. Use `--theme /path/to/theme.json` for another theme. The background slider changes the host background opacity. The roundness and density sliders update the injected theme. Open and Compact select the per-widget presentation, independently of background opacity.

"Fake workspace" and the adjacent scope picker exercise numeric IDs, inclusive ranges, named workspaces and special workspaces inside this window. They do not change a desktop workspace. "Fullscreen layout" expands the selected widget inside the preview canvas. It does not make a desktop window fullscreen. "Catalogue grid" shows all native styles together for inspection.

Every observation is a frozen fixture from `preview-fixtures/snapshots.json`. The artwork is a checked-in SVG labelled "FIXTURE". Weather uses explicitly configured fixture coordinates in London and makes no request. File paths and calendar paths point into `/fixture`. The preview never opens them. Clicking an action records it in the fixture provider log and executes nothing.

The trusted QML examples use the SDK's managed provider requests against the same fixture provider. Native provider adaptors, MPRIS, the broker and shell services are not loaded. Terminal rendering has its own tests and is outside this catalogue preview.

To render and check the source without opening a desktop window:

```sh
./widgets/run-preview.sh --verify
```

Verification uses software Qt rendering, private temporary XDG directories and no display, Wayland or session bus connection. It checks 192 combinations, comprising 14 native styles and two trusted QML examples, each with Open and Compact presentations, normal and fullscreen layouts at minimum, theme and maximum shape settings. Minimum means roundness 0 and density 0.75. Maximum means roundness 2 and density 1.5. It also checks fake workspace hide and reveal behaviour and waits for every gallery host to become ready.

PNG captures and `verification.json` go to `~/.cache/blox-widget-source-preview`. Set `--output /path/to/directory` to change that directory. The captures include a dark catalogue grid, selected fullscreen layouts and a transparent clock. QML warnings fail verification.

These captures prove that the source constructs and renders in the private software Qt fixture. They do not establish live provider correctness, desktop frame freshness or performance acceptance. Nothing installs, reloads or changes the running shell.
