# Native terminal rendering

`Blox.Widgets.Terminal 1.0` contains `TerminalDecoder` and `TerminalSurface`. There is no production Canvas renderer. The broker still owns PTYs, parsing, process lifecycles and its 16 ms publication slots.

Build into an explicit QML import root:

```sh
python3 packaging/build_native_widgets.py --output-import-path /absolute/private/qml
```

The module is `Blox/Widgets/Terminal`. The build helper provides `build(import_root)` and hash-only `validate(import_root, source_root=None)`. Validation never compiles or changes files. Installation must reject missing or stale artefacts before changing the running application.

## Frame delivery

`QuickshellBroker` registers every subscription with `TerminalDecoder`. The decoder frames the JSONL stream in native code and limits a response to 8 MiB of UTF-8. Unknown consumers and stale terminal generations/revisions cannot create native frames. Terminal grids have at most 12,000 cells, 240 columns and 100 rows. Rows must cover their declared columns with ordered, non-overlapping runs. Cell strings contain at most eight Unicode scalars. An empty string is a wide-cell placeholder. ANSI insert, delete and erase operations can leave orphaned or consecutive placeholders in the unchanged parser. The decoder preserves their positions and styles, and the painter skips their glyphs, as Canvas did. Their neighbours need not be wide characters.

The decoder validates a complete retained grid before staging it. QML receives ordinary envelope fields and small terminal metadata, including `frameToken`, `frameRevision` and `nonblankCells`. It never receives terminal `rows` or `changedRuns`. Other provider responses and action acknowledgements retain their existing QML route.

There is one staging slot per live terminal subscription. A token identifies that slot, not a mutable visible frame. `TerminalSurface.frame` adopts a shared immutable grid only when the token, generation, attempt and revision match. WidgetHost must first accept the metadata envelope through its existing guards. Staging a newer observation cannot change a renderer whose host rejected that envelope. Unsubscribe removes the token and invalidates adopted models immediately. Tokens are strings, so retained metadata cannot contain a dangling QObject pointer.

Adoption guards both the source and the surface across synchronous QML notifications. A frame epoch changes on adoption or discard, so a nested setter, clear or unsubscribe wins over an interrupted setter. After discarding an old image, the setter rechecks the token and staged candidate before connecting the source or adopting anything. Geometry, readiness and completion notifications also stop if their callback destroys or supersedes the surface. Image preparation still precedes readiness and host visibility.

The terminal production wire format is `rowFormat: "full-v1"` with `rows`, or
`rowFormat: "patch-v1"` with ordered `[rowIndex, rowObject]` pairs in
`rowPatches`, plus `baseRevision` and `baseSequence`. Both carry the current
generation, attempt, grid, sequence and envelope revision. There is no legacy
reader and no `changedRuns` on this wire. Other providers and controls are unchanged.

OutputQueue compares complete provider rows against its last successfully
serialised frame per consumer. Pending observations may coalesce freely. An
active partial JSON line completes before another observation is serialised.
Cancellation removes the pending observation and its base, while preserving an
already partially written line. Replacement, new attempt, grid change and a
missing base produce a normal full keyframe. Empty observations invalidate the
base. Transport restart starts with a new queue and new decoder subscriptions.

The decoder rejects patches without the exact staged revision, sequence,
generation, attempt and dimensions. It validates every changed row before
staging a complete immutable typed grid. Unchanged rows share Qt vector storage;
a failed patch cannot mutate the staged or adopted frame. Full keyframes use
the same row validator. No decoder error selects another execution path.
The queue retains at most one last row grid per live consumer, capped at 128,
and cancellation or broker shutdown releases it.

## Raster and lifecycle

One shared worker renders images. Its fair queue has at most one pending slot per existing view; each slot reads the latest adopted state when it starts. There is no FIFO of frames. An in-flight frame may finish before the latest pending state. Old generations, attempts and appearances cannot commit after replacement. Cancellation checks run between rows and glyphs. An in-progress Qt font operation cannot be interrupted, but no further glyph work follows a cancellation.

The worker compares against the last committed frame and repaints changed rows. Metadata-only observations do not construct a QPainter or detach the retained image. Hidden prepared views schedule no raster work. First preparation is allowed behind the host's preparing gate, because that gate cannot reveal the view until content exists. Actual host hiding cancels the subscription and destroys or invalidates its source. The worker has no timer or idle polling.

`contentReady` becomes true only after an actual image has been prepared for the adopted generation and attempt. Cold font work stays on the worker and remains part of first-image latency. No synthetic ready frame or startup warm-up moves that boundary. The signal does not claim compositor presentation or complete live TUI frames.

The glyph cache stores outlines, not intermediate raster tiles. Its key includes the complete QFont, cluster and font-database epoch. Colour, cell span, clipping, DPR and fractional position are applied at raster time, not baked into cached data. Outlines are translated before the raster transform to preserve Canvas subpixel coverage. Background and underline rectangles retain run boundaries. The cache has a 4 MiB conservative charged-cost limit and a 2,048-entry limit; oversized outlines bypass it. Qt's own font caches are additional.

The surface owns the primary ARGB32 QImage. It floors logical raster dimensions, rounds physical dimensions with DPR, and checks the exact integers before allocation. The primary image is at most 16 Mi physical pixels and 8,192 pixels per side. Its displayed grid geometry is independent of that cap. Diagnostics report the actual QImage dimensions, bytesPerLine and sizeInBytes. In-flight images, scene-graph textures, native row data, glyph outlines and Qt caches are additional memory, not part of the primary-image limit.

`QQuickWindow::createImageNode()` supplies the image node for the active backend. No private Qt scene-graph API or custom glyph atlas is required. Resource loss rebuilds the node from the prepared image.

## Private checks

All runners accept or use a prebuilt private import root. For the existing render fixtures, set `BLOX_WIDGETS_IMPORT_PATH` to that root.

```sh
python3 widgets/tests/native_terminal.py --import-path /absolute/private/qml --output /absolute/new/checks --dpr 1.25
python3 widgets/tests/quickshell_terminal.py --import-path /absolute/private/qml --output /absolute/new/quickshell
python3 widgets/tests/native_terminal_benchmark.py --import-path /absolute/private/qml --output /absolute/new/bench --variant native --unicode-first
```

The Quickshell check runs the real Process and provider route with a private JSONL fixture, not desktop services or real terminal commands. Offscreen paint counts and software readbacks are not presentation acceptance. Compare a private integrated candidate with the real compositor capture before installation or performance claims.
