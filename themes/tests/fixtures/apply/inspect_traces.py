"""Print the two injected Apply traces alongside terminal results and ledger state."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[4]))

from themes.tests.test_apply_coordinator import ApplyCoordinatorTests, SettingsCore


def inspect(kind: str):
    fixture = ApplyCoordinatorTests("test_core_failure_restores_all_and_offers_no_rollback")
    fixture.setUp()
    try:
        if kind == "coreFailure":
            fixture.core = SettingsCore(fixture.settings, fixture.root)
            fixture.coordinator.core = fixture.core
            fixture.core.fail = True
        else:
            fixture.owners["kitty"].fail = True
        before = {"core": fixture.core.capture(),
                  "kitty": fixture.owners["kitty"].capture(),
                  "wallpaper": fixture.owners["wallpaper"].capture()}
        result = fixture.coordinator.apply(fixture.request)
        fixture.assert_outcome(result, kind)
        after = {"core": fixture.core.capture(),
                 "kitty": fixture.owners["kitty"].capture(),
                 "wallpaper": fixture.owners["wallpaper"].capture()}
        output = {
            "case": kind,
            "trace": fixture.coordinator.trace,
            "result": {
                "code": result["code"], "phase": result["phase"],
                "targets": result["targets"], "actions": result["actions"],
            },
            "ledger": {name: fixture.ledger.read()["components"][name]["status"]
                       for name in ("appearance", "wallpaper")},
            "preStateRestored": before == after,
        }
        if kind == "independentFailure":
            fixture.owners["kitty"].fail = False
            retry = fixture.coordinator.retry_failed_targets()
            fixture.assert_outcome(retry, "retry")
            output["retry"] = {
                "trace": fixture.coordinator.trace,
                "result": {
                    "code": retry["code"], "targets": retry["targets"],
                    "actions": retry["actions"],
                },
                "ledger": {name: fixture.ledger.read()["components"][name]["status"]
                           for name in ("appearance", "wallpaper")},
            }
        return output
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    print(json.dumps([inspect("coreFailure"), inspect("independentFailure")], indent=2))
