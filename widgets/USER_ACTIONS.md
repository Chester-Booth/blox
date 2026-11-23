# First-party widget action helper

`bin/blox-widget-action` runs `shell/scripts/widgets/user_actions.py` from its own tree. It accepts exactly these argv pairs. Nothing reads shell text or producer output as a command.

```text
blox-widget-action todo next
blox-widget-action todo edit
blox-widget-action calendar next
blox-widget-action calendar open
```

The current installer packages this wrapper, helper and launcher together and registers the command in its installed bin links. No profile conversion or compatibility reader exists. Existing user profiles and historical fixtures remain untouched.

## Source context and results

The host must capture the originating workspace before callbacks, merge configured environment, then overwrite the reserved `BLOX_WIDGET_ACTION_CONTEXT` variable. Its entire value is a UTF-8 JSON object of at most 128 bytes, with exactly one field.

```json
{"workspaceId":4}
```

Only an integer from 1 to 2147483647 is representable by the current launcher. Booleans, strings, duplicate fields, extra fields and missing context fail before editor/browser launch. Named and special workspaces return `unavailable`. The helper never reads the focused workspace as a replacement. Selection-only operations do not need a workspace. An auth-expiry notification during generation does need one.

Environment is not proof of origin. The host must own this variable and overwrite it after configuration merging. Views and producer output must never supply it. The helper cannot enforce host eligibility, generation identity, exclusive routing or current-binding authorisation itself.

Each invocation writes one JSON line and exits zero for success, 75 for a busy selection/generation lock, or 1 for other failures. The line contains `ok`, `code`, `message`, `launchAccepted` and `placementVerified`. Selection operations also return `selectedFile`, including the default path when no Todo files exist. This output is an action result, not widget content. Do not feed it into argv construction.

`launchAccepted` is false before any accepted GUI handoff, true after launcher acceptance, or null after a handoff timeout. A timeout is uncertain and never causes a retry. `placementVerified` becomes true only after the editor window and its geometry pass verification. Calendar open leaves it false even on success. Zen may reuse an existing window, so launch acceptance and workspace-1 focus do not prove browser placement. Notification handoffs also count as GUI acceptance.

## Selection and editing

The helper shares `$XDG_STATE_HOME/quickshell/widgets/todo-current` and `gcal-current` with the producers. The default state root is `$HOME/.local/state`. Selection files contain an absolute filename followed by a newline. State replacement uses a temporary file in the same directory, `fsync` and `os.replace`. Publication failure leaves the previous state intact.

Locks retain the existing names, `quickshell/widget-todo.lock` and `quickshell/widget-gcal.lock`, under `$XDG_RUNTIME_DIR`, then `$XDG_CACHE_HOME`, then `$HOME/.cache`. Acquisition waits at most two seconds. The independent `generated-refresh.lock` is nonblocking. Calendar selection releases its lock before attempting generation.

Todo next sorts top-level regular `*.md` paths in the inherited collation locale. It excludes `2-gcal.md`, `80-today.md`, `81-week.md` and `99-gcal_week.md`. It ignores symlinks when enumerating, matching the baseline's `find -type f`. Missing state starts from the first entry, so the first activation selects the second when several exist. A stale selection advances to the first. Cycling wraps. With no files, it returns `1-todo.md` without saving a selection or changing existing state.

Calendar next uses the fixed order `2-gcal.md`, `80-today.md`, `81-week.md`, `99-gcal_week.md`. Missing state first selects `80-today.md`. Unknown state selects `2-gcal.md`.

Editing accepts only top-level Markdown selections under `$HOME/Documents/todo`. It permits a missing creatable file, including the default `1-todo.md`, and rejects escaping paths, escaping symlinks and non-regular targets. A symlinked Todo root is rejected rather than given an implicit alternative root. In-root Markdown symlinks can be edited, but are excluded from cycling. Selection reads are bounded to 4096 bytes. Content and cache reads are bounded to 1 MiB. Filenames remain one literal absolute argument, including whitespace, quotes and shell punctuation.

Micro selection prefers an executable `MICRO_BIN`, then `$HOME/.local/bin/micro` when no override is set, then PATH lookup. The resolved executable path is passed to Kitty with class and title `quickshell_todo`. Dimensions include the producer's filename/position/count heading and content. Width is the longest line's character count times 9 plus 40, at least 200. Height is the line count times 22 plus 40, at least 80. Trailing newlines follow the baseline's command-substitution behaviour. Missing content reads `File not found`.

Before launch, the helper records existing window addresses. It then calls `desktop_exec.launch_detached` with typed argv, a unique launch ID and the captured numeric workspace. It probes at most fifty times, within a five-second startup window. Each compositor query has its own bounded timeout. A matching window must have a new valid address, class `quickshell_todo`, the source workspace ID and a positive PID whose `/proc/PID/environ` contains the launch ID. Existing windows, ambiguous matches and unverified fallback placement cannot count as success.

After a 150 ms wait it checks identity again, floats, focuses, resizes and moves that address to x=60, y=20. It repeats those operations after 50 ms, then verifies floating state, size, coordinates and identity. The action ends on failure or completion. No idle window poll remains. Coordinates preserve the baseline move arguments. They do not establish a multi-monitor geometry contract. A compositor that constrains the requested size or coordinates returns a visible verification failure.

## Calendar generation and ownership

Calendar open attempts Zen with `calendar.google.com`, then focuses workspace 1, then refreshes the calendar files. Each failure is visible. Focus and refresh are still attempted after a failed or uncertain launch, preserving the original effects and order without retrying the handoff.

The new refresh implementation does not invoke `generated-refresh.sh` or `update-gcal-md.sh`. It runs both agenda queries as literal `gcalcli` argv, each with a 25-second limit. It retains their day/week ranges, raw caches and generated Markdown formatting. Weekdays end on Sunday. Saturday and Sunday end on the following Sunday. Failed queries can render cached content with offline, expired or error markers and return failure. A timeout, missing executable or publication error retains existing files. Successful empty formatting can replace a previous file with empty content.

Calendar next also refreshes the expense exports when `EXPENSES_API_BASE_URL` is set. The fixed curl requests retain the two-second connection timeout and 8/6/6-second request limits. Each URL is a literal argument after `--`. Failed downloads preserve their destination files. Other generation steps still run after an individual failure. Successfully published files and the new selection remain in place when a later step fails. No mutating operation retries automatically.

Finite children inherit the action's invocation cgroup and containment namespace. `Runtime.run` uses no shell, new session, background process or service. It drains stdout and stderr through EOF, including after direct exit, with a combined 1 MiB bound. Timeout, cancellation and overflow kill and reap its direct child. The service-main supervisor kills all invocation descendants through cgroup.kill and confirms emptiness and reaping. The caller must provide that owner. Running the helper as an unmanaged process does not supply invocation containment.

Only `Runtime.launch` hands lasting GUI work to `desktop_exec.launch_detached`. The helper never starts Kitty or Zen directly and never detaches the finite generation workflow. Reserved context is removed from the GUI environment. Active cursor environment follows the existing launcher. Arbitrary configured GUI environment overrides are not a supported promise, since compositor launch and fallback currently forward different fields.

The old authentication chain is unsafe to reuse here. `update-gcal-md.sh` can run `systemd-run` or background `gcalcli-auth-notify.sh`. Its Re-authenticate action reaches `gcalcli-init-fix.py`, which starts a browser with a detached `Popen` and calls the old generated refresh. None of those paths is called by this helper. Auth expiry instead hands `notify-send` to the application launcher once per invocation and returns a visible refresh failure. The notification asks for `gcalcli init`. Restoring its interactive Re-authenticate callback needs a separate application-owned route. The notification handoff does not wait for dismissal. Read-only inspection of the locally installed gcalcli authentication code found `open_browser=False`; no installed executable or authentication operation was run. The helper does not claim control over arbitrary replacement executables on PATH.

## Execution ownership

All four bindings use finite `run` records, with caps of 5 seconds for Todo next, 10 seconds for Todo edit, and 120 seconds for both calendar operations. Selection actions retain visible-consumer ownership. The application takes ownership of the exact Todo edit and calendar open workflows before their helper starts, stopping the producer subscription. Their expected GUI-induced workspace transitions do not kill the remaining placement/refresh work. Explicit cancellation, unrelated workspace changes, hiding the host, edits, timeout and application death still kill their finite invocation. See `APPLICATION_ACTIONS.md` for the precise visibility exception and its attribution limit.

The owner refreshes content once after completion, including failure, only if the host is eligible. Hidden producers remain stopped. Completion does not paint helper stdout as content. DesktopWidgets and shell.qml wire application signals, identity, cancellation and originating context. No settings schema or saved profile changes are needed. Source-only changes still require independent review before live verification.

The launcher returns an integer acceptance code, has no PID/route receipt and accepts only positive numeric source workspaces. A captured-workspace launch attempts the compositor handoff once. Dispatcher failure or timeout never starts an unplaced fallback. Todo verifies launch-ID/PID/window/workspace/geometry and reports failure when it cannot. It cannot withdraw an already accepted GUI. Named and special workspace support remains unavailable. Browser reuse remains unverifiable through the current API. `/proc` access or environment sanitisation can also prevent editor verification. Those cases return failure with the accepted handoff recorded.

The application controller supplies current-profile resolution and checks the host through a fixed callback before helper startup and before writing its request. The runtime injects reserved context only through the separate host action channel. The new `first_party.todo_calendar_profile` builder supplies complete finite bindings and explicit caps. DesktopWidgets and shell.qml wire originating context, the application signal, host validation and keyboard focus release. Root still needs to use the existing Apply transaction. See `APPLICATION_ACTIONS.md` for exact APIs. Packaging copies the wrapper, module and launcher dependency together and preserves executable mode on the wrapper. Bindings should use the installed command name. Copying only the executable argv head into a user bundle does not package Python imports or sibling modules. Existing scripts stay until their active callers have been replaced separately. Approved C/D presentation, historical evidence and pins need no change.

## Offline checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s widgets/tests -p test_user_actions.py -v
```

The focused tests use temporary user directories and injected launch, compositor, process, clock and network boundaries. Accidental real subprocess calls fail the test. They cover selection edge cases, shared locks, atomic publication, literal filenames, context rejection, editor identity and dimensions, bounded startup, GUI handoff uncertainty, launch/focus/refresh order, generation failures, calendar ranges, formatting, notification handoff and inherited finite-child execution. No browser, editor, calendar command, network request, hardware call, service, audio action or installation runs. A fake compositor test verifies that an intentional GUI handoff survives finite cleanup while ordinary descendants remain owned. Real compositor routing and native interaction remain unverified.

Service-main ownership, mandatory namespace containment, authenticated literal Qt-child IPC identity and the separate internal safety policy are documented in `OWNERSHIP.md`. No process-group compatibility owner remains.
