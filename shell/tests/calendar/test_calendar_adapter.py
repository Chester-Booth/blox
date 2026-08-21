import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[2] / "scripts" / "calendar"
sys.path.insert(0, str(SCRIPT_DIR))
import calendar_adapter
from calendar_store import CalendarStore


class FakeRequest:
    def __init__(self, result):
        self.result = result
        self.headers = {}

    def execute(self):
        return self.result


class FakeHttpError(RuntimeError):
    def __init__(self, status):
        super().__init__(f"HTTP {status}")
        self.resp = type("Response", (), {"status": status})()


class SequenceRequest(FakeRequest):
    def __init__(self, results):
        super().__init__(None)
        self.results = list(results)
        self.calls = 0

    def execute(self):
        self.calls += 1
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class FakeEvents:
    def __init__(self):
        self.last = None

    def patch(self, **kwargs):
        self.last = FakeRequest({
            "id": kwargs["eventId"], "etag": "new", "summary": kwargs["body"].get("summary", "Event"),
            "start": {"dateTime": "2026-08-12T09:00:00Z"},
            "end": {"dateTime": "2026-08-12T10:00:00Z"},
        })
        return self.last

    def insert(self, **kwargs):
        self.last = FakeRequest({
            **kwargs["body"], "etag": "created",
            "start": kwargs["body"]["start"], "end": kwargs["body"]["end"],
        })
        return self.last

    def get(self, **kwargs):
        self.last = FakeRequest({
            "id": kwargs["eventId"], "etag": "current", "summary": "Created",
            "start": {"dateTime": "2026-08-12T09:00:00Z"},
            "end": {"dateTime": "2026-08-12T10:00:00Z"},
        })
        return self.last


class FakeService:
    def __init__(self):
        self.events_api = FakeEvents()

    def events(self):
        return self.events_api


class FakeRefreshEvents:
    def __init__(self, results):
        self.results = results

    def list(self, **kwargs):
        result = self.results[kwargs["calendarId"]]
        if isinstance(result, Exception):
            return SequenceRequest([result])
        return FakeRequest({"items": result})


class FakeRefreshService:
    def __init__(self, calendars, results):
        self.calendars = calendars
        self.events_api = FakeRefreshEvents(results)

    def calendarList(self):
        return self

    def list(self, **kwargs):
        return FakeRequest({"items": self.calendars})

    def events(self):
        return self.events_api

    def colors(self):
        return self

    def get(self):
        return FakeRequest({"event": {}})


class CalendarAdapterTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = CalendarStore(Path(self.temp.name) / "calendar.sqlite3")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def seed(self, role="owner", allowed=True):
        calendar = {"id": "main", "summary": "Main", "accessRole": role, "write_allowed": allowed}
        event = {"id": "event", "etag": "old", "summary": "Event", "start": {"dateTime": "2026-08-12T09:00:00Z"}, "end": {"dateTime": "2026-08-12T10:00:00Z"}}
        self.store.replace_calendar_slice(calendar, [event], "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")

    def test_adapter_rejects_read_only_before_building_client(self):
        self.seed(role="reader")
        with patch.object(calendar_adapter, "build_gcal_client") as build:
            with self.assertRaises(PermissionError):
                calendar_adapter.mutate(self.store, "update", {"calendar_id": "main", "event_id": "event", "changes": {"summary": "No"}})
        build.assert_not_called()

    def test_update_sends_if_match(self):
        self.seed()
        service = FakeService()
        with patch.object(calendar_adapter, "build_gcal_client", return_value=object()), patch.object(calendar_adapter, "service_from_client", return_value=service):
            result = calendar_adapter.mutate(self.store, "update", {"calendar_id": "main", "event_id": "event", "etag": "old", "changes": {"summary": "Changed"}})
        self.assertEqual(service.events_api.last.headers["If-Match"], "old")
        self.assertEqual(result["event"]["title"], "Changed")

    def test_create_uses_controller_generated_id(self):
        self.seed()
        service = FakeService()
        payload = {
            "calendar_id": "main",
            "create_id": "abc123def456",
            "event": {
                "summary": "Created",
                "start": {"dateTime": "2026-08-12T09:00:00Z"},
                "end": {"dateTime": "2026-08-12T10:00:00Z"},
            },
        }
        with patch.object(calendar_adapter, "build_gcal_client", return_value=object()), patch.object(calendar_adapter, "service_from_client", return_value=service):
            result = calendar_adapter.mutate(self.store, "create", payload)
        self.assertEqual(result["provider_event"]["id"], "abc123def456")
        self.assertEqual(result["event"]["id"], "abc123def456")

    def test_api_execute_retries_only_transient_http_statuses(self):
        request = SequenceRequest([FakeHttpError(503), FakeHttpError(503), {"ok": True}])
        with patch.object(calendar_adapter.time, "sleep") as sleep:
            self.assertEqual(calendar_adapter.api_execute(request), {"ok": True})
        self.assertEqual(request.calls, 3)
        self.assertEqual(sleep.call_count, 2)

        request = SequenceRequest([FakeHttpError(403), {"ok": True}])
        with self.assertRaises(calendar_adapter.ProviderFailure):
            calendar_adapter.api_execute(request)
        self.assertEqual(request.calls, 1)

    def test_api_execute_keeps_uncertainty_after_a_transient_retry(self):
        request = SequenceRequest([FakeHttpError(503), FakeHttpError(404)])
        with patch.object(calendar_adapter.time, "sleep"), self.assertRaises(calendar_adapter.ProviderFailure) as raised:
            calendar_adapter.api_execute(request)
        self.assertEqual(raised.exception.status, 404)
        self.assertTrue(raised.exception.uncertain)

    def test_reconcile_finds_completed_create(self):
        self.seed()
        service = FakeService()
        payload = {
            "operation": "create",
            "request": {
                "calendar_id": "main",
                "create_id": "created-id",
                "event": {
                    "summary": "Created",
                    "start": {"dateTime": "2026-08-12T09:00:00Z"},
                    "end": {"dateTime": "2026-08-12T10:00:00Z"},
                },
            },
        }
        with patch.object(calendar_adapter, "build_gcal_client", return_value=object()), patch.object(calendar_adapter, "service_from_client", return_value=service):
            result = calendar_adapter.reconcile(self.store, payload)
        self.assertEqual(result["state"], "applied")
        self.assertEqual(result["event"]["id"], "created-id")

    def test_error_classification_keeps_status_and_uncertainty(self):
        conflict = calendar_adapter.ProviderFailure(FakeHttpError(412))
        self.assertEqual(calendar_adapter.classify_error(conflict)["code"], "etag_conflict")
        unavailable = calendar_adapter.classify_error(calendar_adapter.ProviderFailure(FakeHttpError(503)))
        self.assertEqual(unavailable["code"], "provider_unavailable")
        self.assertTrue(unavailable["details"]["uncertain"])

    def test_refresh_reports_only_slices_that_completed(self):
        calendars = [
            {"id": "main", "summary": "Main", "accessRole": "owner", "selected": True},
            {"id": "failed", "summary": "Failed", "accessRole": "reader", "selected": True},
        ]
        service = FakeRefreshService(calendars, {"main": [], "failed": FakeHttpError(503)})
        with patch.object(calendar_adapter, "build_gcal_client", return_value=object()), \
                patch.object(calendar_adapter, "service_from_client", return_value=service), \
                patch.object(calendar_adapter, "allow_list", side_effect=lambda value: value), \
                patch.object(calendar_adapter.time, "sleep"):
            result = calendar_adapter.refresh(self.store, "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z")
        self.assertEqual(result["refreshed_calendar_ids"], ["main"])
        self.assertEqual([item["calendar_id"] for item in result["partial_failures"]], ["failed"])


if __name__ == "__main__":
    unittest.main()
