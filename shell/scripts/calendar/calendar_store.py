#!/usr/bin/env python3
"""Disposable SQLite store for the Blox calendar popup."""

from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 2


def default_path() -> Path:
    root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return root / "blox" / "calendar" / "calendar.sqlite3"


class CalendarStore:
    def __init__(self, path: Path | str | None = None):
        self.path = Path(path) if path else default_path()
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.path.parent.stat().st_uid == os.getuid():
            os.chmod(self.path.parent, 0o700)
        self.db = sqlite3.connect(self.path, timeout=2)
        os.chmod(self.path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA busy_timeout=2000")
        self._migrate()

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        with self.db:
            yield

    def _migrate(self):
        with self.db:
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS calendars (
                    id TEXT PRIMARY KEY, summary TEXT NOT NULL, time_zone TEXT,
                    access_role TEXT NOT NULL, is_primary INTEGER NOT NULL DEFAULT 0,
                    selected INTEGER NOT NULL DEFAULT 1, background TEXT,
                    foreground TEXT, write_allowed INTEGER NOT NULL DEFAULT 0,
                    raw_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                    calendar_id TEXT NOT NULL, event_id TEXT NOT NULL, etag TEXT,
                    status TEXT NOT NULL, title TEXT NOT NULL, description TEXT,
                    location TEXT, html_link TEXT, event_type TEXT, locked INTEGER,
                    start_kind TEXT NOT NULL, start_value TEXT NOT NULL,
                    end_value TEXT NOT NULL, start_zone TEXT, end_zone TEXT,
                    colour_id TEXT, recurring_event_id TEXT, original_start TEXT,
                    recurrence_json TEXT, fetched_at_ms INTEGER NOT NULL,
                    raw_json TEXT NOT NULL,
                    PRIMARY KEY (calendar_id, event_id),
                    FOREIGN KEY (calendar_id) REFERENCES calendars(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS events_range ON events(start_value, end_value);
                CREATE INDEX IF NOT EXISTS events_series ON events(recurring_event_id);
                CREATE TABLE IF NOT EXISTS colours (
                    id TEXT PRIMARY KEY, background TEXT NOT NULL,
                    foreground TEXT NOT NULL, fetched_at_ms INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS range_cache (
                    calendar_id TEXT NOT NULL, start_utc TEXT NOT NULL,
                    end_utc TEXT NOT NULL, refreshed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(calendar_id, start_utc, end_utc)
                );
                CREATE TABLE IF NOT EXISTS range_freshness (
                    calendar_id TEXT NOT NULL, start_utc TEXT NOT NULL, end_utc TEXT NOT NULL,
                    refreshed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(calendar_id, start_utc, end_utc)
                );
                CREATE TABLE IF NOT EXISTS operations (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, phase TEXT NOT NULL,
                    calendar_id TEXT, event_id TEXT, request_hash TEXT,
                    before_json TEXT, after_json TEXT, updated_at_ms INTEGER NOT NULL
                );
            """)
            freshness_columns = {
                row["name"] for row in self.db.execute("PRAGMA table_info(range_freshness)")
            }
            if "calendar_id" not in freshness_columns:
                self.db.executescript("""
                    ALTER TABLE range_freshness RENAME TO range_freshness_v1;
                    CREATE TABLE range_freshness (
                        calendar_id TEXT NOT NULL, start_utc TEXT NOT NULL,
                        end_utc TEXT NOT NULL, refreshed_at_ms INTEGER NOT NULL,
                        PRIMARY KEY(calendar_id, start_utc, end_utc)
                    );
                    INSERT OR IGNORE INTO range_freshness
                        (calendar_id,start_utc,end_utc,refreshed_at_ms)
                    SELECT calendars.id,old.start_utc,old.end_utc,old.refreshed_at_ms
                    FROM range_freshness_v1 AS old CROSS JOIN calendars;
                    DROP TABLE range_freshness_v1;
                """)
            self.db.execute("INSERT OR REPLACE INTO meta VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))
            self.db.execute("INSERT OR IGNORE INTO meta VALUES ('revision', '0')")

    @property
    def revision(self) -> int:
        return int(self.db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])

    def bump_revision(self) -> int:
        value = self.revision + 1
        self.db.execute("UPDATE meta SET value=? WHERE key='revision'", (str(value),))
        return value

    def replace_calendar_slice(self, calendar: dict, events: list[dict], start: str, end: str):
        """Replace one fetched range without harming another calendar's warm data."""
        start, end = _utc_iso(start), _utc_iso(end)
        now = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
        with self.db:
            self.db.execute("""INSERT INTO calendars
                (id,summary,time_zone,access_role,is_primary,selected,background,foreground,write_allowed,raw_json)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    summary=excluded.summary, time_zone=excluded.time_zone,
                    access_role=excluded.access_role, is_primary=excluded.is_primary,
                    selected=excluded.selected, background=excluded.background,
                    foreground=excluded.foreground, write_allowed=excluded.write_allowed,
                    raw_json=excluded.raw_json""", (
                calendar["id"], calendar.get("summary", calendar["id"]), calendar.get("timeZone"),
                calendar.get("accessRole", "reader"), bool(calendar.get("primary")),
                calendar.get("selected", True), calendar.get("backgroundColor", "#3978a8"),
                calendar.get("foregroundColor", "#ffffff"), bool(calendar.get("write_allowed")),
                json.dumps(calendar, separators=(",", ":")),
            ))
            self.db.execute("DELETE FROM events WHERE calendar_id=? AND start_value < ? AND end_value > ?", (calendar["id"], end, start))
            for event in events:
                self.upsert_event(calendar["id"], event, now)
            self.db.execute("INSERT OR REPLACE INTO range_cache VALUES (?,?,?,?)", (calendar["id"], start, end, now))
            self.db.execute("INSERT OR REPLACE INTO range_freshness VALUES (?,?,?,?)", (calendar["id"], start, end, now))
            self._merge_coverage(calendar["id"])
            self.bump_revision()

    def _merge_coverage(self, calendar_id: str):
        rows = list(self.db.execute("SELECT start_utc,end_utc,refreshed_at_ms FROM range_cache WHERE calendar_id=? ORDER BY start_utc", (calendar_id,)))
        merged = []
        for row in rows:
            if merged and row["start_utc"] <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], row["end_utc"]), min(merged[-1][2], row["refreshed_at_ms"]))
            else:
                merged.append((row["start_utc"], row["end_utc"], row["refreshed_at_ms"]))
        self.db.execute("DELETE FROM range_cache WHERE calendar_id=?", (calendar_id,))
        self.db.executemany("INSERT INTO range_cache VALUES (?,?,?,?)", ((calendar_id,*item) for item in merged))

    def upsert_event(self, calendar_id: str, event: dict, fetched_at_ms: int | None = None):
        start = event.get("start", {})
        finish = event.get("end", {})
        kind = "all_day" if "date" in start else "timed"
        start_value = start.get("date", start.get("dateTime", ""))
        end_value = finish.get("date", finish.get("dateTime", ""))
        if kind == "timed":
            start_value, end_value = _utc_iso(start_value), _utc_iso(end_value)
        self.db.execute("""INSERT OR REPLACE INTO events VALUES
            (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (
            calendar_id, event["id"], event.get("etag"), event.get("status", "confirmed"),
            event.get("summary", "(No title)"), event.get("description", ""), event.get("location", ""),
            event.get("htmlLink", ""), event.get("eventType", "default"), bool(event.get("locked")),
            kind, start_value, end_value, start.get("timeZone"), finish.get("timeZone"),
            event.get("colorId"), event.get("recurringEventId"),
            json.dumps(event.get("originalStartTime")) if event.get("originalStartTime") else None,
            json.dumps(event.get("recurrence", [])), fetched_at_ms or int(datetime.now(tz=timezone.utc).timestamp() * 1000),
            json.dumps(event, separators=(",", ":")),
        ))

    def delete_event(self, calendar_id: str, event_id: str):
        with self.db:
            self.db.execute("DELETE FROM events WHERE calendar_id=? AND event_id=?", (calendar_id, event_id))
            self.bump_revision()

    def calendar(self, calendar_id: str) -> dict | None:
        row = self.db.execute("SELECT * FROM calendars WHERE id=?", (calendar_id,)).fetchone()
        return dict(row) if row else None

    def event(self, calendar_id: str, event_id: str) -> dict | None:
        row = self.db.execute(
            "SELECT * FROM events WHERE calendar_id=? AND event_id=?",
            (calendar_id, event_id),
        ).fetchone()
        return dict(row) if row else None

    def canonical_event(self, calendar_id: str, event_id: str) -> dict | None:
        row = self.event(calendar_id, event_id)
        if not row:
            return None
        calendar = self.calendar(calendar_id)
        colours = {item["id"]: dict(item) for item in self.db.execute("SELECT * FROM colours")}
        return self._canonical(row, {calendar_id: calendar}, colours)

    def assert_writable(self, calendar_id: str, event_id: str | None = None):
        calendar = self.calendar(calendar_id)
        if not calendar:
            raise ValueError("Unknown calendar")
        if not calendar["write_allowed"] or calendar["access_role"] not in ("writer", "owner"):
            raise PermissionError("This calendar is read-only or not locally allowed")
        if event_id:
            event = self.event(calendar_id, event_id)
            if not event:
                raise ValueError("Unknown event")
            if event["locked"] or (event["event_type"] or "default") != "default":
                raise PermissionError("This event cannot be changed")
        return calendar

    def replace_colours(self, colours: dict):
        now = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
        with self.db:
            for colour_id, colour in colours.items():
                self.db.execute("INSERT OR REPLACE INTO colours VALUES (?,?,?,?)", (
                    str(colour_id), colour.get("background", "#3978a8"),
                    colour.get("foreground", "#ffffff"), now,
                ))
            self.bump_revision()

    def colours_stale(self, max_age_ms: int = 24 * 60 * 60 * 1000) -> bool:
        row = self.db.execute("SELECT MIN(fetched_at_ms) AS oldest, COUNT(*) AS count FROM colours").fetchone()
        now = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
        return not row["count"] or now - row["oldest"] >= max_age_ms

    def snapshot(self, start: str, end: str) -> dict:
        start, end = _utc_iso(start), _utc_iso(end)
        calendars = [dict(row) for row in self.db.execute("SELECT * FROM calendars WHERE selected=1 ORDER BY is_primary DESC, summary")]
        rows = self.db.execute("SELECT * FROM events WHERE status!='cancelled' AND start_value < ? AND end_value > ? ORDER BY start_value, end_value", (end, start))
        colours = {row["id"]: dict(row) for row in self.db.execute("SELECT * FROM colours")}
        by_id = {item["id"]: item for item in calendars}
        events = [self._canonical(dict(row), by_id, colours) for row in rows]
        coverage = [dict(row) for row in self.db.execute("SELECT * FROM range_cache WHERE start_utc <= ? AND end_utc >= ?", (start, end))]
        freshness = [dict(row) for row in self.db.execute("SELECT * FROM range_freshness WHERE start_utc >= ? AND end_utc <= ?", (start, end))]
        covered = {row["calendar_id"] for row in coverage}
        return {"calendars": [self._calendar(c) for c in calendars], "events": events, "coverage": coverage, "range_freshness": freshness,
                "coverage_complete": bool(calendars) and all(c["id"] in covered for c in calendars),
                "coverage_oldest_ms": min((row["refreshed_at_ms"] for row in coverage), default=0)}

    @staticmethod
    def _calendar(row: dict) -> dict:
        return {"id": row["id"], "summary": row["summary"], "time_zone": row["time_zone"] or "", "access_role": row["access_role"], "write_allowed": bool(row["write_allowed"]), "colour": row["background"] or "#3978a8", "primary": bool(row["is_primary"])}

    def _canonical(self, row: dict, calendars: dict, colours: dict) -> dict:
        cal = calendars[row["calendar_id"]]
        allowed = bool(cal["write_allowed"]) and cal["access_role"] in ("writer", "owner") and not row["locked"]
        if row["start_kind"] == "all_day":
            time = {"kind": "all_day", "start_date": row["start_value"], "end_date_exclusive": row["end_value"]}
        else:
            time = {"kind": "timed", "start_ms": _epoch_ms(row["start_value"]), "end_ms": _epoch_ms(row["end_value"]), "start_zone": row["start_zone"], "end_zone": row["end_zone"]}
        provider_colour = colours.get(row["colour_id"], {}).get("background") if row["colour_id"] else None
        recurrence_rules = json.loads(row["recurrence_json"] or "[]")
        return {
            "key": f'{row["calendar_id"]}:{row["event_id"]}', "calendar": self._calendar(cal),
            "id": row["event_id"], "etag": row["etag"], "status": row["status"],
            "event_type": row["event_type"] or "default", "locked": bool(row["locked"]),
            "can_edit": allowed, "capability_reason": "" if allowed else "This calendar is read-only or not locally allowed.",
            "title": row["title"], "description": row["description"] or "", "location": row["location"] or "", "html_link": row["html_link"] or "",
            "time": time, "colour": {"event_id": row["colour_id"], "display": provider_colour or cal["background"] or "#3978a8", "calendar_fallback": cal["background"] or "#3978a8"},
            "recurrence": {"master_id": row["recurring_event_id"], "original_start": row["original_start"], "rules": recurrence_rules,
                           "summary": "Recurring" if row["recurring_event_id"] or recurrence_rules else "", "custom": bool(recurrence_rules)},
            "cache": {"fetched_at_ms": row["fetched_at_ms"], "stale": False, "operation": "idle"},
        }


def _epoch_ms(value: str) -> int:
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)


def _utc_iso(value: str) -> str:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if not parsed.tzinfo:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
