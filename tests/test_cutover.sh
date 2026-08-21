#!/usr/bin/env bash
# Mocked integration tests for packaging/cutover.sh.
# Every failure path must return non-zero; the happy path records success.
# All service interaction goes through stubs; nothing real is touched.
set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CUT="$REPO_DIR/packaging/cutover.sh"
PASS=0
FAIL=0
SANDBOX=""
KEEP="${KEEP:-0}"

LAYER_BAR='[{"monitor":"eDP-1","levels":{"bottom":[{"namespace":"blox-wallpaper-eDP-1"},{"namespace":"blox-bar"}]}}]'
LAYER_NO_BAR='[{"monitor":"eDP-1","levels":{"bottom":[{"namespace":"blox-wallpaper-eDP-1"}]}}]'
LAYER_POPOUT='[{"monitor":"eDP-1","levels":{"bottom":[{"namespace":"blox-bar"}],"top":[{"namespace":"blox-notifications"}]}}]'
UNIT_CONTENT='[Unit]
Description=mock checkout unit
'

say() { printf '%s\n' "$*"; }
teardown() { [ "${KEEP:-0}" = "1" ] && { say "kept: $SANDBOX"; return; }; [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

new_sandbox() {
	teardown
	unset INSTALL_FAIL SYSTEMCTL_FAIL_RELOAD SYSTEMCTL_FAIL_RESTART IPC_FAIL PGREP_TWO
	SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/blox-cutover-test.XXXXXX")
	mkdir -p "$SANDBOX/bin" "$SANDBOX/home/.config/systemd/user" "$SANDBOX/runtime"

	cat > "$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/systemctl.log"
if [ "${SYSTEMCTL_FAIL_RELOAD:-0}" = "1" ] && [ "$2" = "daemon-reload" ]; then exit 1; fi
if [ "${SYSTEMCTL_FAIL_RESTART:-0}" = "1" ] && [ "$2" = "restart" ]; then exit 1; fi
if [ "$2" = "show" ]; then echo 4242; exit 0; fi
exit 0
STUB

	cat > "$SANDBOX/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
count_mode=0
for arg in "$@"; do
	case "$arg" in *c*) count_mode=1 ;; esac
done
if [ "${PGREP_TWO:-0}" = "1" ]; then
	if [ "$count_mode" = "1" ]; then printf '2\n'; else printf '4242\n4243\n'; fi
else
	if [ "$count_mode" = "1" ]; then printf '1\n'; else printf '4242\n'; fi
fi
exit 0
STUB

	cat > "$SANDBOX/bin/bloxctl-installed" <<'STUB'
#!/usr/bin/env bash
if [ "${IPC_FAIL:-0}" = "1" ]; then printf '{"ok":false}'; else printf '{"ok":true,"data":{}}'; fi
exit 0
STUB

	cat > "$SANDBOX/bin/bloxctl-repo" <<'STUB'
#!/usr/bin/env bash
[ "${INSTALL_FAIL:-0}" = "1" ] && exit 3
printf '{"ok":true,"version":"0.1.0","dry_run":false,"plan":{"actions":[],"conflicts":[],"unchanged":0}}\n'
mkdir -p "${HOME}/.local/share/blox"
printf '{"manifest_version":1,"product_version":"0.1.0"}' > "${HOME}/.local/share/blox/manifest.json"
exit 0
STUB

	cat > "$SANDBOX/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

	cat > "$SANDBOX/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "layers" ] && { printf '%s' "$LAYER_JSON"; printf "%s\n" "$LAYER_JSON" >> /tmp/layer-debug.log; }
exit 0
STUB

	chmod +x "$SANDBOX/bin/"*

	git init -q "$SANDBOX/checkout" -b main
	git -C "$SANDBOX/checkout" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed

	printf '%s\n' "$UNIT_CONTENT" > "$SANDBOX/dotfiles-unit"
	ln -sfn "$SANDBOX/dotfiles-unit" "$SANDBOX/home/.config/systemd/user/quickshell.service"
	export LAYER_JSON="$LAYER_BAR"
}

run_cutover() {
	local mode="$1" input="${2:-}"
	HOME="$SANDBOX/home" \
	XDG_STATE_HOME="$SANDBOX/home/.local/state" \
	XDG_RUNTIME_DIR="$SANDBOX/runtime" \
	CHECKOUT_DIR="$SANDBOX/checkout" \
	PATH="$SANDBOX/bin:$PATH" \
	SYSTEMCTL="$SANDBOX/bin/systemctl" \
	JOURNALCTL="$SANDBOX/bin/journalctl" \
	HYPRCTL="$SANDBOX/bin/hyprctl" \
	PGREP="$SANDBOX/bin/pgrep" \
	KILL="true" \
	BLOXCTL_INSTALLED="$SANDBOX/bin/bloxctl-installed" \
	BLOXCTL_REPO_CMD="$SANDBOX/bin/bloxctl-repo" \
	SLEEP="true" \
	CUTOVER_ALLOW_NONINTERACTIVE=1 \
	bash "$CUT" "$mode" <<< "$input" > "$SANDBOX/out.log" 2>&1
}

expect_fail_env() {
	local scenario="$1" setup="$2"
	new_sandbox
	eval "export $setup"
	run_cutover execute "$(printf 'y\ny')"
	if [ "$?" -ne 0 ]; then
		say "PASS  fail-closed: $scenario"
		PASS=$((PASS+1))
	else
		say "FAIL  expected non-zero: $scenario"
		tail -5 "$SANDBOX/out.log"
		FAIL=$((FAIL+1))
	fi
	teardown
}

expect_fail_scenario() {
	local scenario="$1"
	new_sandbox
	run_cutover execute "$(printf 'y\ny')"
	if [ "$?" -ne 0 ]; then
		say "PASS  fail-closed: $scenario"
		PASS=$((PASS+1))
	else
		say "FAIL  expected non-zero: $scenario"
		tail -5 "$SANDBOX/out.log"
		FAIL=$((FAIL+1))
	fi
	teardown
}

expect_ok() {
	local scenario="$1"
	new_sandbox
	run_cutover execute "$(printf 'y\ny')"
	if [ "$?" -eq 0 ] && grep -q "SUCCESS recorded" "$SANDBOX/out.log"; then
		say "PASS  ok: $scenario"
		PASS=$((PASS+1))
	else
		say "FAIL  expected success: $scenario"
		tail -6 "$SANDBOX/out.log"
		FAIL=$((FAIL+1))
	fi
	teardown
}

expect_fail_env "install returns non-zero"   'INSTALL_FAIL=1'
expect_fail_env "daemon-reload fails"        'SYSTEMCTL_FAIL_RELOAD=1'
expect_fail_env "restart fails"              'SYSTEMCTL_FAIL_RESTART=1'
expect_fail_env "ipc envelope not ok"        'IPC_FAIL=1'
expect_fail_env "two quickshell processes"   'PGREP_TWO=1'

new_sandbox; export LAYER_JSON="$LAYER_NO_BAR"
run_cutover execute "y"
if [ "$?" -ne 0 ]; then
	say "PASS  fail-closed: bar layer missing"
	PASS=$((PASS+1))
else
	say "FAIL  expected non-zero: bar layer missing"
	tail -5 "$SANDBOX/out.log"
	FAIL=$((FAIL+1))
fi
teardown

new_sandbox; export LAYER_JSON="$LAYER_POPOUT"
run_cutover execute "y"
if [ "$?" -ne 0 ]; then
	say "PASS  fail-closed: popout namespace open"
	PASS=$((PASS+1))
else
	say "FAIL  expected non-zero: popout namespace open"
	tail -5 "$SANDBOX/out.log"
	FAIL=$((FAIL+1))
fi
teardown

new_sandbox
run_cutover execute "n"
if [ "$?" -ne 0 ]; then
	say "PASS  fail-closed: manual confirmation refused"
	PASS=$((PASS+1))
else
	say "FAIL  confirmation refusal did not fail"
	FAIL=$((FAIL+1))
fi
teardown

expect_ok "full execute with manual confirmation"

new_sandbox
run_cutover execute "$(printf 'y\ny')" >/dev/null 2>&1
run_cutover rollback-checkout "$(printf 'y\ny')"
if [ "$?" -eq 0 ] &&
	[ "$(readlink "$SANDBOX/home/.config/systemd/user/quickshell.service")" = "$SANDBOX/dotfiles-unit" ] &&
	cmp -s "$SANDBOX/dotfiles-unit" <(printf '%s\n' "$UNIT_CONTENT"); then
	say "PASS  rollback restores symlink and keeps target byte-identical"
	PASS=$((PASS+1))
else
	say "FAIL  rollback did not restore the checkout state"
	tail -6 "$SANDBOX/out.log"
	FAIL=$((FAIL+1))
fi
teardown

say "cutover tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
