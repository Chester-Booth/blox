# Compact widget settings checks

Run from the repository root. All output stays in the chosen directory.

```sh
/usr/bin/python tests/fixtures/compact-widget-settings/run.py --output /tmp/blox-compact-check --density 0.75 --radius 0
/usr/bin/python tests/fixtures/compact-widget-settings/run.py --output /tmp/blox-compact-check --capture --name content
/usr/bin/python tests/fixtures/compact-widget-settings/run.py --output /tmp/blox-compact-check --capture --name action-bottom --tab 1 --action left --advanced --expanded --bottom
/usr/bin/python tests/fixtures/compact-widget-settings/run.py --output /tmp/blox-compact-narrow --capture --name narrow --width 400 --height 340 --density 1.5 --radius 2 --tab 4 --bottom
```

Without `--capture`, the runner executes `tst_SettingsWidgetCompact.qml`. It types into the real Blox fields, selects combo boxes through keyboard events, navigates tabs, drags the scrollbar and saves through the production controller's existing profile callback. The test checks the staged profile and reopens it. It also checks nested validation, failed staging and other modal sizes.

Captures load the production modal, widget editor and draft controller. `scene.qml` provides sample values through the existing draft methods. It uses a profile callback as the Settings host does. Captures do not click Save or implement a substitute Save handler. The separate interaction suite exercises Save.

The runner copies current Blox control source bytes into an isolated import directory and records their SHA-256 hashes. Co-locating the controls with the theme adapter avoids loading the real Theme singleton through an implicit local import. The adapter uses the approved B reference palette and fonts, with the production spacing and radius formulae. Icons use Blox's existing Controls icon renderer and the real Phosphor SVGs, because the shell's GPU effect does not tint under software rendering. The isolated FileView test double uses Item's existing default data list to avoid the original stub's member override warning.

Qt uses offscreen/software rendering, isolated HOME and XDG directories, and nonexistent D-Bus socket paths. Quickshell APIs use the repository's test doubles. No shell command, widget broker, desktop, service or installed Blox instance runs. PNGs and geometry reports go into `images/` and `logs/`. Each invocation records its exact child command and exit code. Warnings fail the suite and captures.

Use separate output directories for concurrent runs. Supported density extremes are 0.75 and 1.5. Supported roundness extremes are 0 and 2. These checks establish offscreen layout and interaction behaviour only. They do not establish live desktop acceptance, GPU rendering, broker execution, installation behaviour or performance.
