#!/usr/bin/env bash
# Blox live cutover and checkout rollback.
#
# Modes:
#   plan              print everything that would happen; change nothing
#   execute           preflight, back up units, install (+migrate), restart
#                     Quickshell once, verify
#   rollback-checkout restore the backed-up unit links, restart once,
#                     verify against the checkout
#
# Nothing here restarts a service until you pass execute or
# rollback-checkout AND answer y at its prompt.

set -uo pipefail

MODE="${1:-plan}"
# The checkout location is machine-specific and deliberately has no
# default: pass CHECKOUT_DIR=/path/to/dotfiles for every mode.
CHECKOUT_DIR="${CHECKOUT_DIR:-}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
BACKUP_ROOT="$STATE_HOME/blox/backups"
UNITS=("$HOME/.config/systemd/user/quickshell.service" "$HOME/.config/systemd/user/gcal-update.service")
PREFLIGHT_FAILURES=0

say()  { printf '%s\n' "$*"; }
fail() { printf 'PREFLIGHT FAIL: %s\n' "$*" >&2; PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES+1)); }

unit_backup_dir() {
	local latest
	latest=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "cutover-*" 2>/dev/null | sort | tail -1)
	printf '%s' "$latest"
}

preflight() {
	say "== preflight =="
	[ -n "${XDG_RUNTIME_DIR:-}" ] || fail "XDG_RUNTIME_DIR is not set; no user session?"
	for tool in systemctl jq git sha256sum; do command -v "$tool" >/dev/null || fail "missing tool: $tool"; done
	command -v hyprctl >/dev/null || say "note: hyprctl missing; window observation must be manual"
	[ -n "$CHECKOUT_DIR" ] || fail "CHECKOUT_DIR is required (path to this machine's dotfiles checkout)"
	[ -d "$CHECKOUT_DIR/.git" ] || fail "checkout not found: $CHECKOUT_DIR"
	[ -f "$HOME/.local/bin/bloxctl" ] || say "note: product not installed yet (expected before first execute)"
	if [ "$MODE" = "rollback-checkout" ]; then
		[ -n "$(unit_backup_dir)" ] || fail "no cutover backup found under $BACKUP_ROOT/cutover-*"
	fi
	if [ "$PREFLIGHT_FAILURES" -gt 0 ]; then
		say "refusing to continue: $PREFLIGHT_FAILURES preflight failure(s)"
		exit 1
	fi
	say "checkout:      $(git -C "$CHECKOUT_DIR" rev-parse HEAD)"
	say "installed:     $(jq -r .product_version "$HOME/.local/share/blox/manifest.json" 2>/dev/null || echo none)"
	say ""
}

backup_units() {
	local stamp dir link target
	stamp=$(date +%Y%m%dT%H%M%S)
	dir="$BACKUP_ROOT/cutover-$stamp"
	mkdir -p "$dir"
	for link in "${UNITS[@]}"; do
		[ -e "$link" ] || continue
		cp -P "$link" "$dir/$(basename "$link")"
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

verify_shell() {
	say "== verification =="
	local main_pid processes ipc bar
	main_pid=$(systemctl --user show -p MainPID --value quickshell.service)
	if [ -n "$main_pid" ] && [ "$main_pid" != "0" ] && kill -0 "$main_pid" 2>/dev/null; then
		processes=$(pgrep -x quickshell | wc -l)
		say "PASS  main process alive: pid $main_pid ($processes quickshell process(es))"
	else
		say "FAIL  quickshell.service has no live main process"
		journalctl --user -u quickshell.service -n 15 --no-pager || true
		return 1
	fi
	ipc=$("$HOME/.local/bin/bloxctl" status --json 2>/dev/null | jq -r ".ok" || true)
	if [ "${ipc:-}" = "true" ]; then
		say "PASS  IPC status round trip"
	else
		say "FAIL  IPC status unreachable or envelope not ok"
	fi
	if command -v hyprctl >/dev/null; then
		bar=$(hyprctl clients -j 2>/dev/null | jq '[.[] | select(.class == "org.quickshell")] | length')
		say "PASS  quickshell surfaces visible: $bar (expect the bar; manually confirm ONE bar and NO open popouts)"
	else
		say "MANUAL  confirm one bar and no open popouts"
	fi
}

restart_once() {
	say "== controlled restart =="
	systemctl --user daemon-reload
	systemctl --user restart quickshell.service
	sleep 8
}

case "$MODE" in
plan)
	say "== PLAN (nothing will be changed) =="
	preflight
	say "execute would:"
	say "  1. copy -P the current unit files/links into $BACKUP_ROOT/cutover-<ts>/"
	say "  2. \$HOME/Code/blox/bin/bloxctl lifecycle install --prefix \"\$HOME/.local\"   (migrations run inside this transaction)"
	say "  3. systemctl --user daemon-reload && systemctl --user restart quickshell.service   (exactly one restart)"
	say "  4. verify: one live main process, IPC status ok, one bar, no open popouts"
	say "rollback-checkout would:"
	say "  1. restore the newest cutover backup with cp -P (symlinks recreated from .linktarget)"
	say "  2. systemctl --user daemon-reload && restart once"
	say "  3. verify against the checkout shell"
	;;
execute)
	preflight
	say "== about to cut over to the installed product =="
	read -r -p "Type y to proceed: " answer
	[ "$answer" = "y" ] || { say "aborted"; exit 125; }
	backup_units
	"$HOME/Code/blox/bin/bloxctl" lifecycle install --prefix "$HOME/.local" || { say "install failed; nothing was restarted"; exit 1; }
	restart_once
	verify_shell
	say ""
	say "Rehearse the way back any time with: $0 rollback-checkout"
	;;
rollback-checkout)
	preflight
	say "== about to return the machine to the checkout =="
	read -r -p "Type y to proceed: " answer
	[ "$answer" = "y" ] || { say "aborted"; exit 125; }
	dir=$(unit_backup_dir)
	for link in "${UNITS[@]}"; do
		name=$(basename "$link")
		[ -f "$dir/$name" ] || continue
		if [ -f "$dir/$name.linktarget" ]; then
			ln -sfn "$(cat "$dir/$name.linktarget")" "$link"
			say "restored symlink $link -> $(cat "$dir/$name.linktarget")"
		else
			cp -P "$dir/$name" "$link"
			say "restored file $link"
		fi
	done
	restart_once
	verify_shell
	;;
*)
	say "usage: $0 {plan|execute|rollback-checkout}" >&2
	exit 2
	;;
esac
