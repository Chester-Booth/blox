#!/usr/bin/env python3
"""JSON command entry point for the Settings Apply backend."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PRODUCT_ROOT = Path(__file__).resolve().parents[2]
if str(PRODUCT_ROOT) not in sys.path:
    sys.path.insert(0, str(PRODUCT_ROOT))

from themes.lib.blox_theme.apply_coordinator import ApplyError
from themes.lib.blox_theme.apply_owners import create_apply, open_existing_apply


def error_status(coordinator=None):
    """Report retained recovery state; a failed read cannot prove journal release."""
    try:
        owner = coordinator if coordinator is not None else open_existing_apply()
        status = owner.status()
        if status is not None:
            return {**status, "journalReleased": False}
        return {"phase": "none", "journalReleased": True, "recoveryAvailable": False,
                "targets": {}, "actions": {"retryFailedTargets": [], "keepSuccessfulChanges": False,
                                            "rollBack": False, "cancel": False}}
    except ApplyError as error:
        if str(error) == "no Apply transaction exists":
            return {"phase": "none", "journalReleased": True, "recoveryAvailable": False,
                    "targets": {}, "actions": {"retryFailedTargets": [], "keepSuccessfulChanges": False,
                                                "rollBack": False, "cancel": False}}
    except Exception:
        pass
    return {"phase": "unknown", "journalReleased": False, "recoveryAvailable": True,
            "targets": {}, "actions": {"retryFailedTargets": [], "keepSuccessfulChanges": False,
                                        "rollBack": False, "cancel": False}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "status", "retry", "keep", "rollback", "recover", "finish", "abandon", "review", "drift-keep", "drift-reapply"))
    parser.add_argument("--theme", help="theme ID or path for apply")
    parser.add_argument("--approvals", default="{}", help="JSON object of approved path to SHA-256")
    parser.add_argument("--target")
    args = parser.parse_args(argv)
    coordinator = None
    try:
        from shell.scripts.settings_document import SettingsDocument
        from themes.lib.blox_theme.core import load_theme
        from themes.lib.blox_theme.component_bundle import review_export
        from themes.lib.blox_theme import runtime
        def stream(event):
            print(json.dumps({"event": event}), flush=True)
        if args.action == "review":
            _, theme = load_theme(args.theme)
            settings = SettingsDocument().get()
            if not settings.ok:
                raise ApplyError("Settings read failed: " + settings.code)
            current = runtime.current_generation()
            drift = None
            if current and 'gtk' in current[1]['enabled_targets'] and settings.data['targets']['gtk']['enabled']:
                checks = runtime.loader_checks()
                changed = [value['path'] for key, value in checks.items() if key.startswith('gtk') and key.endswith('generated_links') and not value['ok']]
                if changed:
                    drift = {"target": "gtk", "label": "GTK appearance", "paths": changed,
                             "observedAt": "Observed now", "managed": current[1]['theme_id'],
                             "expected": "Blox generated files", "current": "External files or links"}
            result = {"scripts": review_export(theme, settings.data, "full"), "drift": drift}
        elif args.action == "drift-keep":
            if args.target != 'gtk':
                raise ApplyError("unsupported drift target")
            owner = SettingsDocument()
            current = owner.get()
            if not current.ok:
                raise ApplyError("Settings read failed")
            saved = owner.set('targets.' + args.target + '.enabled', False, current.revision)
            if not saved.ok:
                raise ApplyError('Settings changed before drift decision: ' + saved.code)
            result = {"target": args.target, "disabled": True}
        elif args.action == "drift-reapply":
            if args.target != 'gtk':
                raise ApplyError("unsupported drift target")
            manifest, errors = runtime.reconcile((args.target,))
            if errors:
                raise ApplyError('; '.join(errors))
            result = {"target": args.target, "generationId": manifest['generation_id']}
        elif args.action == "apply":
            if not args.theme:
                raise ApplyError("apply requires --theme")
            approvals = json.loads(args.approvals)
            if not isinstance(approvals, dict):
                raise ApplyError("approvals must be an object")
            coordinator, request = create_apply(args.theme, approvals=approvals)
            coordinator.event_sink = stream
            result = coordinator.apply(request)
        else:
            try:
                coordinator = open_existing_apply()
            except ApplyError as error:
                if args.action in ("status", "recover") and str(error) == "no Apply transaction exists":
                    result = None
                else:
                    raise
            else:
                coordinator.event_sink = stream
                operation = {"status": coordinator.status, "retry": coordinator.retry_failed_targets,
                             "keep": coordinator.keep_successful_changes, "rollback": coordinator.roll_back,
                             "recover": coordinator.recover, "finish": coordinator.finish,
                             "abandon": coordinator.abandon_superseded_partial}[args.action]
                result = operation()
        succeeded = not isinstance(result, dict) or result.get("code") != "core-failure"
        print(json.dumps({"version": 1, "ok": succeeded, "code": result.get("code", "ok") if isinstance(result, dict) else "ok",
                          "data": result}, sort_keys=True))
        return 0 if succeeded else 1
    except (ApplyError, ValueError, OSError, KeyError, TypeError) as error:
        status = error_status(coordinator)
        print(json.dumps({"version": 1, "ok": False, "code": "apply-error", "data": status,
                          "error": status.get('error') or str(error)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
