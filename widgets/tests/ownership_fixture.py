"""Lightweight test fixture helper for widget process-group ownership tests."""
from __future__ import annotations

import os
from pathlib import Path
import time


class SupervisionFixture:
    """Minimal compatibility fixture for widget tests after removing the daemon."""

    def __init__(self):
        self._events: list[dict] = []

    def start(self):
        return self

    def pythonpath(self, extra=""):
        lib = str(Path(__file__).resolve().parents[1] / "lib")
        return os.pathsep.join(part for part in (lib, extra) if part)

    def environment(self, base=None, **changes):
        result = dict(os.environ if base is None else base, **changes)
        result["PYTHONPATH"] = self.pythonpath(result.get("PYTHONPATH", ""))
        return result

    def bind_clock(self, clock):
        return None

    def events(self):
        return list(self._events)

    def assert_members(self, case, leader, pids):
        for pid in pids:
            case.assertEqual(os.getpgid(pid), leader.pgid)
        case.assertFalse(leader.closed)

    def assert_closed(self, case, leader):
        case.assertTrue(leader.closed)

    def close(self):
        return None
