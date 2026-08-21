import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[2] / "scripts" / "calendar"
sys.path.insert(0, str(SCRIPT_DIR))
from calendar_store import CalendarStore


class CalendarStoreTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = CalendarStore(Path(self.temp.name) / "calendar.sqlite3")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_slice_round_trips_timed_and_all_day_events(self):
        calendar = {"id": "main", "summary": "Main", "timeZone": "Europe/London", "accessRole": "owner", "primary": True, "write_allowed": True, "backgroundColor": "#3978a8"}
        events = [
            {"id": "timed", "summary": "Lecture", "etag": "one", "start": {"dateTime": "2026-08-12T09:00:00Z", "timeZone": "Europe/London"}, "end": {"dateTime": "2026-08-12T10:00:00Z", "timeZone": "Europe/London"}},
            {"id": "all-day", "summary": "Results", "start": {"date": "2026-08-12"}, "end": {"date": "2026-08-13"}},
        ]
        self.store.replace_calendar_slice(calendar, events, "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        result = self.store.snapshot("2026-08-12T00:00:00Z", "2026-08-13T00:00:00Z")
        self.assertEqual({event["id"] for event in result["events"]}, {"timed", "all-day"})
        self.assertTrue(all(event["can_edit"] for event in result["events"]))
        self.assertEqual(next(e for e in result["events"] if e["id"] == "all-day")["time"]["end_date_exclusive"], "2026-08-13")
        self.assertEqual(result["calendars"][0]["time_zone"], "Europe/London")

    def test_narrow_refresh_keeps_events_outside_the_slice(self):
        calendar = {"id": "main", "summary": "Main", "accessRole": "owner", "write_allowed": True}
        events = [
            {"id": "today", "summary": "Today", "start": {"dateTime": "2026-08-13T09:00:00Z"}, "end": {"dateTime": "2026-08-13T10:00:00Z"}},
            {"id": "later", "summary": "Later", "start": {"dateTime": "2026-08-20T09:00:00Z"}, "end": {"dateTime": "2026-08-20T10:00:00Z"}},
        ]
        self.store.replace_calendar_slice(calendar, events, "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        self.store.replace_calendar_slice(calendar, [events[0]], "2026-08-13T00:00:00Z", "2026-08-14T00:00:00Z")
        result = self.store.snapshot("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        self.assertEqual({event["id"] for event in result["events"]}, {"today", "later"})

    def test_composite_keys_keep_duplicate_provider_ids(self):
        for calendar_id in ("main", "study"):
            calendar = {"id": calendar_id, "summary": calendar_id, "accessRole": "reader", "backgroundColor": "#3978a8"}
            event = {"id": "same", "summary": calendar_id, "start": {"dateTime": "2026-08-12T09:00:00Z"}, "end": {"dateTime": "2026-08-12T10:00:00Z"}}
            self.store.replace_calendar_slice(calendar, [event], "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        keys = {event["key"] for event in self.store.snapshot("2026-08-12T00:00:00Z", "2026-08-13T00:00:00Z")["events"]}
        self.assertEqual(keys, {"main:same", "study:same"})

    def test_writes_require_provider_and_local_permission(self):
        self.store.replace_calendar_slice(
            {"id": "read", "summary": "Read", "accessRole": "reader", "write_allowed": True},
            [], "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        with self.assertRaises(PermissionError):
            self.store.assert_writable("read")

    def test_locked_event_cannot_be_written(self):
        calendar = {"id": "main", "summary": "Main", "accessRole": "owner", "write_allowed": True}
        event = {"id": "locked", "locked": True, "start": {"dateTime": "2026-08-12T09:00:00Z"}, "end": {"dateTime": "2026-08-12T10:00:00Z"}}
        self.store.replace_calendar_slice(calendar, [event], "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        with self.assertRaises(PermissionError):
            self.store.assert_writable("main", "locked")

    def test_coverage_normalises_offsets_and_merges(self):
        calendar = {"id": "main", "summary": "Main", "accessRole": "owner", "write_allowed": True}
        self.store.replace_calendar_slice(calendar, [], "2026-06-30T23:00:00Z", "2026-08-01T00:00:00+01:00")
        self.store.replace_calendar_slice(calendar, [], "2026-07-31T23:00:00Z", "2026-09-01T00:00:00+01:00")
        result = self.store.snapshot("2026-07-01T00:00:00+01:00", "2026-08-31T23:00:00Z")
        self.assertTrue(result["coverage_complete"])
        self.assertEqual(len(result["coverage"]), 1)

    def test_exact_range_freshness_survives_coverage_merge_and_reopen(self):
        calendar = {"id": "main", "summary": "Main", "accessRole": "owner", "write_allowed": True}
        self.store.replace_calendar_slice(calendar, [], "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        self.store.replace_calendar_slice(calendar, [], "2026-08-12T00:00:00Z", "2026-08-13T00:00:00Z")
        path = self.store.path
        self.store.close()
        self.store = CalendarStore(path)
        result = self.store.snapshot("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        ranges = {(row["start_utc"], row["end_utc"]) for row in result["range_freshness"]}
        self.assertIn(("2026-08-12T00:00:00Z", "2026-08-13T00:00:00Z"), ranges)

    def test_range_freshness_is_scoped_to_each_calendar(self):
        for calendar_id in ("main", "study"):
            self.store.replace_calendar_slice(
                {"id": calendar_id, "summary": calendar_id, "accessRole": "owner", "write_allowed": True},
                [], "2026-08-12T00:00:00Z", "2026-08-13T00:00:00Z")
        result = self.store.snapshot("2026-08-12T00:00:00Z", "2026-08-13T00:00:00Z")
        self.assertEqual({row["calendar_id"] for row in result["range_freshness"]}, {"main", "study"})


if __name__ == "__main__":
    unittest.main()
