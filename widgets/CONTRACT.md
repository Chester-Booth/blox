# Widget rebuild contract

18 October 2026. This is the new implementation. No old-format reader, migration, legacy preset alias or fallback runtime belongs here. Production cutover waits for complete Settings/theme integration and parity checks. The existing installed shell is not changed by this source work.

The first native catalogue is clock, music, system, network, calendar, notes, files and shortcuts. Weather is optional and requires an explicitly configured location/provider. [Command output](COMMAND.md) displays complete stdout as plain text. [Terminal](TERMINAL.md) runs TUIs in a PTY. Trusted community QML is another extensibility route. A and B guide individual visuals, not a compulsory composition. Background opacity affects the background only, never content opacity.

## Storage

A profile is `{schemaVersion: 1, widgets: [...]}`. Each item has exactly these fields:

- `id`: unique lowercase kebab identifier, `kind`: clock/music/system/network/calendar/notes/files/shortcuts/weather/command/terminal/qml, `name`: visible name, `enabled`: boolean.
- `placement`: `{anchor, x, y, width, height, sizing?}`. Anchors are top-left/top-right/bottom-left/bottom-right/centre. x/y are signed integer offsets; positive right/bottom offsets point inwards. Dimensions are positive integer logical pixels. `sizing` is `fixed` by default or `content` to measure the view and clamp its viewport and position inside the placement bounds. New command widgets use content sizing.
- `workspaces`: `{mode: "all"|"include", ids: [integer|string], ranges: [[inclusiveIntegerStart,inclusiveIntegerEnd],...]}`. IDs are exact numeric or named/special workspace identities, never regexes. Include with no selectors matches nothing.
- `visibility`: "always"|"empty-workspace".
- `appearance`: `{backgroundOpacity: number0to1, scrollbars: "auto"|"show"|"hide"}`.
- `fullscreen`: `{enabled: boolean, mode: "native"|"resize"|"fit"|"scroll"|"crop"}`. Native built-ins use native; terminal may use resize, fit or scroll; trusted QML uses its declared layouts. Fullscreen never draws scrollbars, and normal placement is unchanged.
- `settings`: kind-specific validated object. No old command/profile fields.

Use a single validated document for source/profile, Settings drafts and portable export. The live per-user profile belongs to the existing Settings document and Apply transaction. Apply publishes current/widgets/profile.json, the sole runtime source. The standalone ProfileStore CLI uses XDG_CONFIG_HOME/blox/widgets.json only when explicitly invoked as a separate editing tool. Its output must be imported or applied through Settings to change the shell. It is never an automatic runtime fallback. Theme integration must emit/consume this same format, without converting old items. No automatic write on read or preview. Writes use revision/digest conflict detection and atomic replace. Imports reject old formats clearly. Trust for executing commands/QML is explicit in documentation; a manifest is not a sandbox.

## Public QML module

`widgets/qml/Blox/Widgets` is the source of `import Blox.Widgets 1.0`. No Quickshell imports in WidgetView, WidgetHost or Native visuals. Module search path is supplied by the host/preview. `WidgetTheme` is a QtObject with mutable palette/font/radiusScale/densityScale values, injected by host rather than global installed theme reads.

`WidgetView` is the base Item. Properties: `context` var, `settings` var, `fullscreen` bool, `theme` var, `snapshot` var, `contentReady` bool. Built-in visuals derive readiness from the matching snapshot and their actual resources. Signals `actionRequested(string action, var payload)` and `readinessChanged` as appropriate. Host owns all windows, focus and placement; views create none.

`WidgetHost` receives `widget` var, `theme` var, `provider` var, `workspace` var `{id,name,special,empty}`, `fullscreen` bool, and `editing` bool. It exposes `view`, `phase` hidden/preparing/visible/unavailable, `revealGeneration`, `snapshot`, and emits `actionRequested`. `contentWidth`/`contentHeight` expose the view's natural size. `normalWidth`/`normalHeight` expose the normal viewport size, including during fullscreen. `placementBounds` controls normal geometry. `fullscreenBounds` defaults to those same bounds and can be set separately. Provider has subscribe(consumerId,provider,options,generation), unsubscribe(consumerId), snapshotReady(consumerId,envelope), and dispatchAction(consumerId,action,payload,generation,hostContext). Provider names follow kind; notes/shortcuts need no external data; qml may declare providers later. Reuse work only for equivalent options and real consumers.

Eligibility change increments generation and invalidates permission to display the previous generation. Hide stops animation/subscriptions, cancels old work and ignores late responses. On reveal, obtain fresh data, valid layout and resources before content visibility. Never intentionally display an old hidden frame then catch up. Do not delay workspace switching. Native-frame generation acceptance still requires later real rendering tests; a QML ready flag alone is not physical proof.

Snapshot envelope: `{generation:int, revision:int, observedMonotonicMs:number, state:"preparing"|"ready"|"unavailable", value:object, error:string}`. A provider emits a fresh observation, not a renamed stale cache timestamp. Pending/unavailable are explicit; no synthetic live values. Clock computes current wall time on reveal and shares visible minute/second ticks. Music derives current progress from valid player state. Graph gaps remain gaps.

## Broker protocol

One optional stdlib Python process serves system/network/calendar/files/weather/command/terminal consumers. Clock/music can use dedicated shared native QML adaptors. JSONL stdin operations carry `requestId`, `op` subscribe/unsubscribe/action/shutdown; subscribe includes `consumerId`, `provider`, `options`, `generation`. Responses are `{consumerId, snapshot:<envelope>}` or a typed request error. Bounded line/output sizes and worker timeouts; no shell execution for native metrics. Calendar, files and weather use at most four short-lived read workers that the broker kills and reaps on timeout, unsubscribe or shutdown. CPU/network reads stay in the broker. Backpressure retains one latest observation per consumer, sharing source values, and serialises one frame as stdout drains. Terminal rendering detects skipped sequences and repaints complete retained rows. No samples with zero consumers. One process may retain bounded idle memory but must do no periodic work with no consumers. No per-widget Python daemon.

System value: cpuPercent nullable, cpuFrequencyGHz nullable, cpuTemperatureC nullable, memoryUsedBytes, memoryTotalBytes, memoryPercent, powerW nullable, uptimeSeconds, history bounded. Network: interfaces array of `{name,rxBytesPerSecond,txBytesPerSecond}`, aggregate rates and bounded history; first rate requires two samples. Calendar: local calendar store snapshot/events and source observation; remote sync is separate. Files: configured directory, bounded entries, no execute. Weather: configured coordinates, bounded asynchronous read-only request; no location inference/default network call.

Command output owns non-overlapping one-shot process groups and publishes only complete successful stdout. Its combined stdout/stderr limit is 1 MiB, with a 60 second poll and 15 second timeout by default. Failure reports an error and retains the last same-generation success. Hide cancels and reaps the invocation. Details are in [COMMAND.md](COMMAND.md).

Terminal module owns PTYs and process groups under the broker. New cell/run snapshots, no HTML rich-text bridge. Incremental UTF-8 decoding, bounded grid/output, resize and deterministic cancellation. Existing parser behaviour may be extracted and improved, but old entrypoints/preset mappings are removed at cutover. Fresh PTY generation never accepts old output. Arbitrary output does not prove full-screen freshness: explicit first-frame readiness limitation, no invented completion heuristic.

## Implementation boundaries

Do not install, reload the live shell or use screen/workspace/input control. Use private offscreen fixtures and subprocess-owned tests. Keep simulated data labelled in previews and out of production providers. No performance acceptance claim from these fixtures. The 2x/3x requirements and timing boundaries remain unchanged.
