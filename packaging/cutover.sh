#!/usr/bin/env bash
# Blox live cutover and checkout rollback.
#
# Modes:
#   plan              print everything that would happen; change nothing
#   execute           preflight, back up units, install (+migrate), restart
#                     Quickshell once, verify, require manual confirmation
#   rollback-checkout restore the backed-up unit links, restart once,
#                     verify against the checkout
#
# Fail closed: every critical step is checked and any failure returns
# non-zero. Nothing restarts a service until execute/rollback-checkout is
# passed AND answered y at its prompt AND the post-restart observation is
# manually confirmed.

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SELF_DIR/.." && pwd)"

MODE="${1:-plan}"
CHECKOUT_DIR="${CHECKOUT_DIR:-}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
BACKUP_ROOT="$STATE_HOME/blox/backups"
UNITS=("$HOME/.config/systemd/user/quickshell.service" "$HOME/.config/systemd/user/gcal-update.service")

# Command shims: tests inject stubs through these.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
JOURNALCTL="${JOURNALCTL:-journalctl}"
HYPRCTL="${HYPRCTL:-hyprctl}"
PGREP="${PGREP:-pgrep}"
BLOXCTL_INSTALLED="${BLOXCTL_INSTALLED:-$HOME/.local/bin/bloxctl}"
BLOXCTL_REPO_CMD="${BLOXCTL_REPO_CMD:-$REPO_DIR/bin/bloxctl}"
SLEEP="${SLEEP:-sleep}"
KILL="${KILL:-kill}"

POPOUT_NAMESPACES='["blox-launcher-main","blox-notifications","blox-osd","blox-shortcut-guide","blox-widget-edit"]'

say()  { printf '%s\n' "$*"; }
die()  { printf 'CUTOVER FAIL: %s\n' "$*" >&2; exit 1; }

unit_backup_dir() {
	find "$BACKUP_ROOT" -maxdepth 1 -type d -name "cutover-*" 2>/dev/null | sort | tail -1
}

PREFLIGHT_STRICT="${PREFLIGHT_STRICT:-1}"

preflight() {
	local failures=0
	say "== preflight =="
	[ -n "${XDG_RUNTIME_DIR:-}" ] || { say "FAIL  XDG_RUNTIME_DIR is not set"; failures=$((failures+1)); }
	for tool in "$SYSTEMCTL" jq git sha256sum "$PGREP"; do
		command -v "$tool" >/dev/null || { say "FAIL  missing tool: $tool"; failures=$((failures+1)); }
	done
	[ -n "$CHECKOUT_DIR" ] || { say "FAIL  CHECKOUT_DIR is required"; failures=$((failures+1)); }
	if [ -n "$CHECKOUT_DIR" ] && [ ! -d "$CHECKOUT_DIR/.git" ]; then
		say "FAIL  checkout not found: $CHECKOUT_DIR"
		failures=$((failures+1))
	fi
	[ -f "$HOME/.local/share/blox/manifest.json" ] && \

	if [ "$MODE" = "rollback-checkout" ] && [ -z "$(unit_backup_dir)" ]; then
		say "FAIL  no cutover backup under $BACKUP_ROOT/cutover-*"
		failures=$((failures+1))
	fi
	if [ "$failures" -gt 0 ]; then
		if [ "$PREFLIGHT_STRICT" = "1" ]; then
			die "$failures preflight failure(s)"
		fi
		say "warning: $failures preflight failure(s); continuing because this is a plan"
	fi
	local revision
	revision=$(git -C "$CHECKOUT_DIR" rev-parse HEAD) || die "cannot read checkout revision"
	say "checkout:  $revision"
}

backup_units() {
	say "== unit backup =="
	local stamp dir link target
	stamp=$(date +%Y%m%dT%H%M%S)
	dir="$BACKUP_ROOT/cutover-$stamp"
	mkdir -p "$dir" || die "cannot create backup directory"
	for link in "${UNITS[@]}"; do
		[ -e "$link" ] || continue
		cp -P "$link" "$dir/$(basename "$link")" || die "backup failed for $link"
		if [ -L "$link" ]; then
			target=$(readlink "$link")
			printf '%s\n' "$target" > "$dir/$(basename "$link").linktarget"
			say "backed up symlink $link -> $target"
		else
			say "backed up regular file $link"
		fi
	done
	say "backup directory: $dir"
}

install_product() {
	say "== install (migrations run inside the transaction) =="
	local report="$BACKUP_ROOT/install-report.json"
	"$BLOXCTL_REPO_CMD" lifecycle install --prefix "$HOME/.local" --json > "$report" \
		|| die "lifecycle install returned non-zero; nothing was restarted"
	jq -e '.ok == true' "$report" >/dev/null || die "install envelope not ok; nothing was restarted"
	say "installed $(jq -r .version "$report")"
}

reload_restart() {
	say "== controlled restart (exactly one) =="
	"$SYSTEMCTL" --user daemon-reload || die "daemon-reload failed"
	"$SYSTEMCTL" --user restart quickshell.service || die "restart failed"
	"$SLEEP" 8
}

verify_shell() {
	say "== verification =="
	local main_pid count ipc layers bar popouts

	main_pid=$("$SYSTEMCTL" --user show -p MainPID --value quickshell.service)
	if [ -z "$main_pid" ] || [ "$main_pid" = "0" ] || ! "$KILL" -0 "$main_pid" 2>/dev/null; then
		$JOURNALCTL --user -u quickshell.service -n 15 --no-pager 2>/dev/null || true
		die "quickshell.service has no live main process"
	fi
	say "PASS  main process alive: pid $main_pid"

	count=$("$PGREP" -xc quickshell 2>/dev/null | tail -1)
	count=${count:-0}
	[ "$count" = "1" ] || die "expected exactly one quickshell process, found ${count:-0}"
	say "PASS  exactly one quickshell process"

	ipc=$("$BLOXCTL_INSTALLED" status --json 2>/dev/null | jq -r ".ok" || true)
	[ "${ipc:-}" = "true" ] || die "IPC status round trip failed or envelope not ok"
	say "PASS  IPC status round trip"

	if command -v "$HYPRCTL" >/dev/null 2>&1; then
		layers=$("$HYPRCTL" layers -j 2>/dev/null) || die "hyprctl layers query failed"
		bar=$(printf '%s' "$layers" | jq '[.[] | .levels[]?[]? | select(.namespace == "blox-bar")] | length' 2>/dev/null) \
			|| die "could not parse hyprctl layers output"
		[ "$bar" = "1" ] || die "expected exactly one blox-bar layer, found ${bar:-unknown}"
		popouts=$(printf '%s' "$layers" | jq --argjson known "$POPOUT_NAMESPACES" \
			'[.[] | .levels[]?[]? | select(.namespace as $n | $known | index($n))] | length' 2>/dev/null) \
			|| die "could not parse hyprctl layers output"
		[ "$popouts" = "0" ] || die "found $popouts open popout surface(s): close them and rerun"
		say "PASS  exactly one blox-bar layer, no known popout namespaces"
	else
		say "MANUAL  hyprctl unavailable: confirm one bar and no open popouts below"
	fi

	printf 'Confirm visually — one bar, no open popouts, shell healthy. Type y to record success: '
	read -r answer
	[ "$answer" = "y" ] || die "manual confirmation refused; treating cutover as failed"
	say "SUCCESS recorded for this mode."
}

case "$MODE" in
plan)
	PREFLIGHT_STRICT=0
	say "== PLAN (nothing will be changed) =="
	preflight
	say "execute would:"
	say "  1. cp -P current units into $BACKUP_ROOT/cutover-<ts>/ with recorded symlink targets"
	say "  2. $BLOXCTL_REPO_CMD lifecycle install --prefix \"\$HOME/.local\"  (migrations inside the transaction)"
	say "  3. daemon-reload + one restart of quickshell.service"
	say "  4. fail-closed verification: one live process, exactly one quickshell PID, IPC ok,"
	say "     hyprctl layers show exactly one blox-bar and no known popout namespaces,"
	say "     then explicit manual confirmation"
	say "rollback-checkout would:"
	say "  1. restore newest backup via cp -P (symlinks recreated from .linktarget)"
	say "  2. one restart, same fail-closed verification"
	;;
execute)
	[ -t 0 ] || [ "${CUTOVER_ALLOW_NONINTERACTIVE:-0}" = "1" ] || die "refusing non-interactive execute"
	preflight
	say "== about to cut over to the installed product =="
	read -r -p "Type y to proceed: " answer
	[ "$answer" = "y" ] || { say "aborted"; exit 125; }
	backup_units
	install_product
	reload_restart
	verify_shell
	say ""
	say "Rehearse the way back any time with: $0 rollback-checkout"
	;;
rollback-checkout)
	[ -t 0 ] || [ "${CUTOVER_ALLOW_NONINTERACTIVE:-0}" = "1" ] || die "refusing non-interactive rollback"
	preflight
	say "== about to return the machine to the checkout =="
	read -r -p "Type y to proceed: " answer
	[ "$answer" = "y" ] || { say "aborted"; exit 125; }
	local_dir=$(unit_backup_dir)
	die_if_empty() { [ -n "$1" ] || die "no backup directory"; }
	die_if_empty "$local_dir"
	for link in "${UNITS[@]}"; do
		name=$(basename "$link")
		[ -f "$local_dir/$name" ] || continue
		if [ -f "$local_dir/$name.linktarget" ]; then
			ln -sfn "$(cat "$local_dir/$name.linktarget")" "$link" || die "failed to restore symlink $link"
			say "restored symlink $link -> $(cat "$local_dir/$name.linktarget")"
		else
			cp -P "$local_dir/$name" "$link" || die "failed to restore file $link"
			say "restored file $link"
		fi
	done
	reload_restart
	verify_shell
	;;
*)
	say "usage: $0 {plan|execute|rollback-checkout}" >&2
	exit 2
	;;
esac
