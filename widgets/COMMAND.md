# Command output

`command` runs a one-shot argv and displays its completed stdout as ordinary Qt text. Use `terminal` for an interactive command or TUI. Command output has no PTY, ANSI parser, terminal grid or implicit shell.

Create the complete settings object through `default_widget` or the catalogue defaults:

```python
from blox_widgets import default_widget

widget = default_widget('command', 'public-output', {
    'command': ['printf', '%s\n', 'Public fixture'],
})
```

`command` is required. `workingDirectory` is an absolute directory or an empty string for the broker's inherited directory. `environment` adds or replaces environment variables. The default `intervalSeconds` is 60 and `timeoutSeconds` is 15. The next poll is due one interval after the previous invocation started. A missed deadline permits one invocation after the previous one finishes. Invocations never overlap and missed polls do not accumulate.

The shared broker reads nonblocking stdout and stderr pipes. Each sample reads at most 65536 bytes with a cooperative 10 ms read deadline. Active commands are serviced every 50 ms. Between invocations the broker waits until the next provider deadline. Its selector still responds immediately to input, and pending workers keep their progress checks and terminal readiness wakes the selector. With no consumers or pending cleanup it has no timer. Success requires exit code zero and EOF on both pipes. Only then does the provider decode stdout as UTF-8, replace malformed sequences, trim surrounding whitespace and publish the complete string in one snapshot. Embedded newlines and indentation remain. Stderr is drained but never displayed or retained as diagnostic text. Markup and escape sequences remain plain text.

Stdout and stderr share a 1 MiB byte limit for each invocation. Exactly 1048576 bytes is allowed. Exceeding it stops the invocation and reports `Command output exceeds 1 MiB`. It never publishes a truncated success. Timeout, nonzero exit and startup failure also report explicit errors. A failure retains only the last successful text from the same live subscription. A successful empty result clears the text. A new reveal or data configuration starts with no previous output.

Command snapshots have `value: {text, error, exitCode, bytesObserved, action}`. The envelope repeats `error` and uses `state: "ready"` for completed attempts, including failures, so the view can show the error beside retained output. `exitCode` is null if no exit status was available when cancellation began. The host's `error` property exposes the envelope error. A transport failure uses the host's unavailable state and clears its old generation.

Complete settings also require `actions`, with exactly `left` and `right`. Each binding is null, a finite `run`, or an application `launch`. New drafts default to two null bindings. Saved settings must contain both keys. Readers do not add them.

```json
{
  "actions": {
    "left": {
      "kind": "run",
      "command": ["blox-widget-action", "todo", "next"],
      "workingDirectory": "",
      "environment": {},
      "timeoutSeconds": 5
    },
    "right": {
      "kind": "run",
      "command": ["blox-widget-action", "todo", "edit"],
      "workingDirectory": "",
      "environment": {},
      "timeoutSeconds": 10
    }
  }
}
```

This is an authoring example. `blox_widgets.first_party.todo_calendar_profile(script_root)` builds a new complete Todo/calendar profile with all four finite bindings. `examples/first-party-actions.profile.json` is its synthetic fixture. Neither changes existing user data. Desktop application wiring is implemented. Actual user Apply remains separate work. See `USER_ACTIONS.md` and `APPLICATION_ACTIONS.md`.

A run binding requires argv, absolute-or-empty cwd, environment and a timeout between 0.01 and 120 seconds. A launch binding requires only `kind` and argv. Launch cwd, environment and workspace overrides are invalid. Content and both bindings share the 65536-byte UTF-8 argv/environment budget. The complete settings object has a 49152-byte ASCII-encoded JSON budget. Nested rules apply to every binding. Removed shell-string click fields remain invalid.

An ordinary accepted run cancels and reaps the producer, keeps the last successful text and pauses periodic work. One action can run per consumer. Further clicks return `busy` without a queue. The same finite invocation implementation owns both kinds of process. Action stdout and stderr share the 1 MiB bound and are drained without becoming content or commands. Direct exit plus both pipe EOFs and confirmed cgroup cleanup completes an action. Timeout, overflow, hide, configuration replacement and broker death clean up its cgroup, including descendants that retain pipes after direct exit.

Every completed action attempt, including failure or startup failure, schedules exactly one immediate producer invocation. Its start sets the next regular deadline. The host generation stays unchanged. A successful empty refresh clears previous content. Hide or replacement cancels pending refresh and never replays the action on reveal or reconnect.

`value.action` has `state: "idle"`, `"running"` or `"finished"` and a nullable `result`. A finished result has `code`, `exitCode`, `error` and `bytesObserved`. Codes are `success`, `failed`, `timeout` and `output-limit`. Producer errors remain separate. Invalid or busy actions do not change the content observation. Broker action acknowledgements have the operation, consumer and generation plus `result.code`, either `accepted` or `busy`. Invalid requests return a generation-bound action error. The adapter reports these through `actionResult` and never converts them into unavailable content.

CommandView emits only `activate` and a left/right button. Taps activate on release and cancel when dragging. Wheel input, scrollbar controls, fullscreen controls and outside gestures do not activate. With application-assigned keyboard focus, Return, Enter and Space activate left; Menu and Shift+F10 activate right. Auto-repeat does not activate. Arrow and page keys scroll. Escape releases view focus and signals `WidgetHost.focusReleaseRequested`. Neither loading nor tapping takes keyboard focus.

The host resolves the current binding and rechecks configuration, eligibility, generation and adapter identity after observation callbacks. Ordinary run actions go exclusively to the provider. Launch actions and the two fixed GUI workflows below emit `applicationActionRequested` with widget/consumer identity, generation and button. They do not enter the broker. The application must resolve the binding again against its current enabled profile and own lasting GUI startup. `WidgetActionController` implements the application owner. DesktopWidgets and shell connect the signal and its fixed host validator. An uncertain launch never retries.

`WidgetHost.trustedLaunchContext` is reserved for application-supplied output/workspace context and defaults to null. The host captures a copy before callbacks and supplies it on the separate launch signal or the reserved provider action argument. Profile fields, action payloads, environment and stdout cannot set it. Command settings reject the reserved `BLOX_WIDGET_ACTION_CONTEXT` environment key, and finite invocations remove any inherited value. Only the separate command action channel can restore the reserved variable after merging and stripping environment. The translated helper value is exactly `{ "workspaceId": 4 }`. DesktopWidgets populates `{outputName, workspace: {id, name, special}}` from the originating output workspace. Positive numeric workspaces are supported. Named/special workspaces return unavailable without an unplaced fallback. Content producers never receive action context. DesktopWidgets handles `focusReleaseRequested` through its exact keyboard host owner.

Each invocation belongs to a unique cgroup beneath the Quickshell service root. The service-main supervisor places a trusted gated child before configured execution, requires a private user/cgroup namespace with nsdelegate, and owns absolute deadlines, cgroup.kill and reaping. Completion requires direct exit, output EOF, an empty invocation subtree and confirmed cleanup. Broker death, owner lease expiry, hide, timeout and output overflow cancel the invocation. Supervisor death invokes systemd's whole-service cleanup. Missing delegation or containment returns unavailable; no process-group fallback exists. The one shared supervisor and its lifecycle work remain included in service-root CPU and memory counters. See `OWNERSHIP.md` for the exact contract, internal safety ceilings and remaining platform assumptions.

The view uses `Text.PlainText`, `Text.NoWrap`, the theme's body font, 15 logical pixel text and 24 logical pixel padding by default. `fontFamily` overrides the theme font when nonempty. `fontSize` sets the text size in logical pixels without scaling by spacing density, while `padding` is multiplied by the theme's `densityScale`. These presentation settings and density changes update the existing view without restarting its command. Errors wrap in a separate text area. The host supplies `context.availableWidth`, calculated independently of content height, so the view can measure the wrapped error without a sizing cycle. The viewport dimensions stay nonnegative when bounds are too small for the padding and error. Errors clip within the remaining height and do not cover retained stdout.

New command widgets default to `placement.sizing: "content"`. The host measures the view's implicit dimensions and clamps the viewport and position inside `placementBounds`. The unclamped natural dimensions remain available as `contentWidth` and `contentHeight`. `normalWidth` and `normalHeight` expose the resulting normal viewport dimensions even during fullscreen. Explicit `fixed` sizing, or an omitted sizing field, uses the configured placement width and height. Normal overflow can scroll.

Fullscreen fills `fullscreenBounds`, which follows `placementBounds` unless the application overrides it. It keeps the normal placement, measured dimensions and running subscription. Both fullscreen scrollbars are always hidden.

Run the focused checks from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=widgets/lib python3 -m unittest discover -s widgets/tests -p test_command.py -v
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=widgets/lib python3 -m unittest discover -s widgets/tests -p test_providers.py -k command -v
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_QUICK_CONTROLS_STYLE=Basic QT_QPA_PLATFORMTHEME= QML_DISABLE_DISK_CACHE=1 /usr/lib/qt6/bin/qmltestrunner -import widgets/qml -input widgets/tests/qml/tst_CommandOutput.qml -o -,txt
```

These checks use owned Python commands, public fixture strings and offscreen Qt. The transport test needs an existing Quickshell executable and skips if it is unavailable. They do not build native modules, install files or contact the live desktop. Shell/theme integration and compositor frame acceptance remain separate checks.

## Fixed GUI workflows

The exact `blox-widget-action todo edit` and `blox-widget-action calendar open` run bindings use the application's finite workflow owner. The producer stops before helper execution. Todo may finish placement after the source workspace becomes occupied; calendar may finish refresh after focusing workspace 1. Hidden producers stay unsubscribed, and other run bindings still cancel on hide. Explicit cancellation, configuration changes and application shutdown kill the finite invocation. See `APPLICATION_ACTIONS.md` for the hooks, bounds and visibility tradeoff.
