# Widget SDK

Add `widgets/qml` to the QML import path, then import `Blox.Widgets 1.0`. This source module needs Qt Quick, not Quickshell. It does not read an installed theme or start a provider process.

```qml
import QtQuick
import Blox.Widgets 1.0

WidgetView {
    id: root
    contentReady: snapshot !== null && snapshot.state === "ready"
    Text {
        anchors.centerIn: parent
        text: root.contentReady ? root.settings.title || "" : ""
        color: root.theme.palette.foreground
        font.family: root.theme.fontFamily
    }
}
```

The host supplies `context`, `settings`, `fullscreen`, `theme` and `snapshot` before component completion. `settings` is the kind-specific object, or the inner `settings.settings` object for a trusted QML manifest. `snapshot` is the full envelope in [CONTRACT.md](CONTRACT.md). A view sets `contentReady` only when the matching observation and resources can be displayed. Images and other asynchronous resources must also be ready. Never set it merely because the component was constructed.

`context` contains `consumerId`, `generation`, `workspace`, `editing`, `fullscreenMode`, `scrollbars`, `data`, `requestData`, `releaseData`, `requestAction` and `requestRefresh`. The scrollbar policy is `auto`, `show` or `hide`. Fullscreen always supplies `hide`. Views own no windows, workspace switching, focus policy or placement. The context does not expose the raw provider adapter.

`WidgetHost.actionRequested(action, payload)` observes accepted view gestures. It is not a second execution owner. Native music and terminal actions go to their provider. Files, shortcuts, notes and calendar retain application handling without provider forwarding. Community views call `context.requestAction(action, payload, providerName)` to address a declared managed request. They can omit the provider name when exactly one request exists. After observation callbacks, the host rechecks eligibility, edit mode, generation, configuration and adapter identity before forwarding.

Command views emit only `activate` with `{button: "left"}` or `{button: "right"}`. The host resolves the current complete settings binding. Run actions go to the command provider only. Launch bindings emit the separate `applicationActionRequested(action, identity, trustedContext)` signal only, where identity contains `widgetId`, `consumerId`, `generation` and `button`. No view-supplied argv or workspace is accepted. Applications must resolve live configuration again and explicitly connect this signal to their launcher. `WidgetActionController` resolves launch bindings against the current enabled application profile. DesktopWidgets and shell.qml wire its fixed host callback and the separate launch signal. `first_party.todo_calendar_profile` authors new complete Todo/calendar bindings without loading user profiles.

Applications may supply `WidgetHost.trustedLaunchContext` from the originating output/workspace. This reserved property defaults to null and has no profile, environment or output override. The host captures it before callbacks. Its shape is `{outputName, workspace: {id, name, special}}`. The application context validator accepts positive numeric workspaces only. Named and special workspaces are explicitly unavailable. `WidgetHost.isCurrentAction(identity, trustedContext)` checks the current host subscription, generation, eligibility, edit state and captured context for the fixed application callback. See `APPLICATION_ACTIONS.md`. `focusReleaseRequested()` lets the application clear its keyboard-widget focus when CommandView handles Escape. The view never grabs focus automatically.

Provider adapters implement `dispatchAction(consumerId, action, payload, generation, hostContext)` and reject a generation that does not match their current subscription. The optional fifth argument is reserved for application-supplied command context. Views cannot set it. It travels as top-level `hostContext`, separate from payload and settings, and never persists across refresh or reconnect. Broker action requests and responses carry that generation. `NativeProvider.actionResult(consumerId, generation, result)` reports immediate acknowledgement, busy and request errors separately from content. Command completion status lives in the command snapshot. Pending action tracking is bounded, cleared on unsubscribe/disconnect and never replayed. See `COMMAND.md` for finite ownership, completion refresh and action schemas.

`WidgetTheme` has mutable `palette`, `fontFamily`, `monospaceFamily`, `fontSize`, `font`, `radiusScale` and `densityScale` properties. Palette keys are `background`, `foreground`, `muted`, `accent`, `border`, `positive`, `warning` and `negative`. `font` exposes `family`, `size` and `monospaceFamily` for callers that prefer a map. A host can inject its own compatible theme object. Content must retain full opacity. The host draws the background separately using `appearance.backgroundOpacity`.

## Hosting

```qml
WidgetHost {
    widget: validatedProfile.widgets[0]
    theme: applicationTheme
    provider: applicationProviders
    workspace: currentWorkspace
    placementBounds: Qt.rect(0, 0, parent.width, parent.height)
    onActionRequested: function(action, payload) {
        // Observe gestures. Dispatch only application-owned native actions here.
    }
    onApplicationActionRequested: function(action, identity, trustedContext) {
        // Root integration resolves the current launch binding and owns the handoff.
    }
}
```

The application validates the profile, supplies the provider and owns every window. Provider methods and signals follow [CONTRACT.md](CONTRACT.md). The SDK never imports a live provider. `view`, `phase`, `revealGeneration`, `snapshot`, `error` and `consumerId` expose runtime state. `phase` is `hidden`, `preparing`, `visible` or `unavailable`.

Every eligibility change or change to the widget ID, kind, data settings or trusted manifest registry immediately hides the old content, increments the generation and unsubscribes. Geometry, fullscreen presentation and workspace changes that leave the widget eligible update its existing view without restarting the provider. Native clock, system, calendar and music style changes also retain the current observation and subscription. Command font and padding changes retain the running invocation and its completed output. Their data options still request a fresh generation. Music artwork selection remains a data option because the provider includes or omits the artwork URL. Preparation requests a fresh observation. Old generations and repeated revisions cannot reveal content. An unavailable observation may recover on a later revision. A provider-wide `connectionError(message)` invalidates the generation and clears content while retaining subscription demand so the adapter can retry. Hide still cancels that demand. Its optional `reconnected()` signal replaces the old subscriptions in a fresh generation. Adaptors without these signals can call `refresh()` when their connection changes.

A QML readiness gate checks data and resources. It does not prove that the compositor has presented a fresh physical frame. Rendering acceptance needs later tests on the real host.

`placementBounds` defines logical coordinates for normal anchors. `fullscreenBounds` follows it by default and can be set independently to fill a separate fullscreen area. Positive offsets at the right and bottom point inwards. Fullscreen geometry never mutates the profile placement. `placement.sizing` is `fixed` by default. `content` measures the view's implicit dimensions and clamps its viewport and position inside the normal bounds. Content-sized views must provide useful implicit dimensions independent of their viewport. `contentWidth` and `contentHeight` expose these natural dimensions. `normalWidth` and `normalHeight` expose the resulting normal viewport dimensions even during fullscreen. `editing` makes enabled widgets eligible across workspace and empty-workspace filters, so the application can add its own editing controls. It does not create controls or request focus.

For completed plain stdout, use the `command` kind and its [command output contract](COMMAND.md). It uses the theme body font at 15 pixels with 24 pixel padding by default. `terminal` is the PTY route for TUIs.

## Trusted community QML

Profiles name a manifest, never a source URL. The application installs and reviews QML, then supplies a trusted registry such as:

```qml
qmlRegistry: ({
    "my-clock": {
        source: Qt.resolvedUrl("community/MyClock.qml"),
        layouts: ["native"],
        providers: ["clock"]
    }
})
```

The profile's QML settings are `{manifest, layouts, providers, settings}`. The host checks declared layouts and providers against the registry before loading its source. The QML route supplies a local ready envelope with an empty value for `snapshot`. That envelope describes component preparation, not an external observation.

Request external observations during component completion:

```qml
readonly property var clock: context.data ? context.data.clock : null
contentReady: snapshot !== null && snapshot.state === "ready"
    && clock !== null && clock.state === "ready"
Component.onCompleted: context.requestData("clock", {style: "digital", timezone: "local", format: "24h", showSeconds: false})
```

Provider options use the complete validated settings object for that kind, including required defaults. Partial objects are rejected. Both the profile and trusted registry must declare `clock`. `requestData(providerName, options, required)` returns an opaque consumer ID. `required` defaults to `true`. `context.data[providerName]` contains the full current envelope, initially `preparing`. The host waits for every requested required provider to be ready in the current generation before revealing the view. A required unavailable envelope makes the host unavailable. A later ready revision can recover it.

Pass `false` as the third argument for optional data. Optional pending or unavailable observations do not block the host. The view can still require an optional resource in its own `contentReady` expression if its chosen layout needs it. A view's readiness can extend the host gate, never bypass required provider readiness.

The host allows one request per provider name, with at most sixteen declared providers. Repeating a request with the same JSON options and required flag returns the existing handle. Changing either cancels the previous request and starts a new one. Options must be a JSON object with at most 65,536 serialised characters. Call `releaseData(providerName)` to stop a request explicitly. Hide, configuration changes and refresh cancel all requests even if the author has no teardown handler. Connection errors clear data and invalidate the generation while retaining demand for adapter retry. Hiding during an outage cancels that retained demand too. Consumer IDs belong to a widget and generation. Late callbacks, replaced handles and repeated revisions cannot satisfy the current gate or overwrite its data. One widget's cancellation never cancels another widget's handle.

`requestRefresh()` starts a fresh generation. Functions retained from an old context cannot subscribe or send actions after that generation ends. The clock and music examples use this managed API. Their preview injects a simulated provider with the same protocol.

QML, plain output commands and terminal commands are trusted executable code. A manifest is not a security sandbox. QML authors can import other modules installed on the machine, so the application must review the files it registers. Never register a source URL from untrusted profile text.

## Installing a trusted QML package

Place each reviewed package in `$XDG_DATA_HOME/blox-user/widgets/<package-directory>`. Without `XDG_DATA_HOME`, use `~/.local/share/blox-user/widgets`. This user-owned directory is separate from the installed application code. A package contains these files:

```text
my-clock/
  widget.json
  Main.qml
```

`widget.json` has exactly these fields:

```json
{
  "id": "my-clock",
  "name": "My clock",
  "layouts": ["native"],
  "providers": ["clock"]
}
```

The ID is a lowercase kebab identifier of at most 64 characters. The name has at most 128 characters. Layouts are a nonempty, unique subset of `native`, `resize`, `fit`, `scroll` and `crop`. Providers use the native catalogue names, including `command` and `terminal`, with no duplicates. `Main.qml` imports the public module and can request only providers declared in both its manifest and the profile. Other package files can contain reviewed QML components or assets.

Discover packages without loading their code:

```sh
PYTHONPATH=widgets/lib python3 -m blox_widgets.cli registry
```

For a private fixture, add `--root /absolute/package-directory`. The command returns `{ok: true, registry: {...}, errors: [...]}`. Runtime and Settings use that same registry map. Every entry contains `source`, `layouts`, `providers` and `name`; `source` is the resolved local URL of `Main.qml`.

Discovery reads manifests but never parses or executes QML, starts providers, or installs files. It rejects missing files, invalid declarations, duplicate JSON fields and symlinks that escape the package. Packages themselves must remain inside the registry root. Duplicate package IDs have no winner. Invalid packages appear in `errors` and are omitted while valid packages remain available. A missing directory returns an empty registry. A root I/O failure or more than 256 package directories returns the CLI's standard error envelope with exit status 2. Each manifest is limited to 64 KiB.

Installing a package makes its trusted executable QML available for an explicit profile selection. The registry is a file discovery mechanism, not a security sandbox. Review packages before placing them in this directory. Portable profiles reference manifest IDs and do not copy or download executable package files.

## Examples and tests

`examples/Clock.qml` and `examples/Music.qml` only import the public module. `examples/Preview.qml` provides labelled simulated observations. Run from the repository root with:

```sh
/usr/lib/qt6/bin/qml -I widgets/qml widgets/examples/Preview.qml
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input widgets/tests/qml/tst_WidgetHost.qml -import widgets/qml -o -,txt
```

The tests use private QML fixtures and fake providers. They do not contact D-Bus, change workspaces or control the desktop.
