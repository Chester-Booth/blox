"""Read-only native observations. Paths and HTTP transport are injectable for tests."""
from __future__ import annotations

import json
import math
import os
import sqlite3
import time
import threading
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

MAX_FILE_BYTES = 1024 * 1024


def read_text(path: Path, limit: int = MAX_FILE_BYTES) -> str:
    with path.open('rb') as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Source exceeds read limit')
    return data.decode('utf-8', errors='replace')


def optional_number(path: Path, divisor: float = 1) -> float | None:
    try:
        number = float(read_text(path, 128).strip()) / divisor
        return number if math.isfinite(number) else None
    except (OSError, ValueError):
        return None


def bounded_int(value, default, low, high):
    if value is None:
        return default
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'Expected integer between {low} and {high}')
    return value


class Provider:
    interval = 1.0
    asynchronous = False

    def close(self):
        pass


class ClockProvider(Provider):
    def __init__(self, options, **_):
        self.zone = options.get('timezone', 'local')
        self.tz = None if self.zone == 'local' else ZoneInfo(self.zone)
        self.seconds = options.get('showSeconds', True)
        self.format = options.get('format', '24h')
        self.interval = 1 if self.seconds else 60

    def sample(self, now):
        current = datetime.now(self.tz) if self.tz else datetime.now().astimezone()
        return {'epochMs': current.timestamp() * 1000, 'iso': current.isoformat(),
                'timeZone': self.zone, 'hour': current.hour, 'minute': current.minute,
                'second': current.second, 'day': current.day, 'month': current.month,
                'year': current.year, 'date': current.date().isoformat(),
                'text': current.strftime(('%I:%M:%S' if self.seconds else '%I:%M') + ' %p' if self.format == '12h' else ('%H:%M:%S' if self.seconds else '%H:%M'))}

    def next_delay(self):
        # Wall boundaries keep clocks aligned, including after a clock adjustment.
        return max(.01, self.interval - time.time() % self.interval)


class SystemProvider(Provider):
    def __init__(self, options, proc_root='/proc', sys_root='/sys', **_):
        self.proc, self.sys = Path(proc_root), Path(sys_root)
        self.interval = bounded_int(options.get('intervalSeconds'), 1, 1, 60)
        self.history = deque(maxlen=bounded_int(options.get('historySize'), 60, 2, 240))
        self.previous = None

    def sample(self, now):
        cpu = next(line for line in read_text(self.proc / 'stat').splitlines() if line.startswith('cpu '))
        values = [int(x) for x in cpu.split()[1:9]]
        total, idle = sum(values), values[3] + (values[4] if len(values) > 4 else 0)
        percent = None
        if self.previous:
            old_now, old_total, old_idle = self.previous
            elapsed, delta = now - old_now, total - old_total
            if 0 < elapsed <= self.interval * 3 and delta > 0 and 0 <= idle - old_idle <= delta:
                percent = 100 * (delta - (idle - old_idle)) / delta
        self.previous = (now, total, idle)
        memory = {}
        for line in read_text(self.proc / 'meminfo').splitlines():
            parts = line.split()
            if len(parts) > 1:
                memory[parts[0].rstrip(':')] = int(parts[1]) * 1024
        total_mem = memory['MemTotal']
        available = memory.get('MemAvailable', memory.get('MemFree', 0))
        used = max(0, total_mem - available)
        frequency = optional_number(self.sys / 'devices/system/cpu/cpu0/cpufreq/scaling_cur_freq', 1e6)
        if frequency is None:
            try:
                freqs = [float(line.split(':', 1)[1]) / 1000 for line in read_text(self.proc / 'cpuinfo').splitlines() if line.startswith('cpu MHz')]
                frequency = sum(freqs) / len(freqs) if freqs else None
            except (OSError, ValueError):
                pass
        temperatures = []
        for path in sorted((self.sys / 'class/thermal').glob('thermal_zone*/temp'))[:64]:
            temp = optional_number(path, 1000)
            if temp is not None and -40 <= temp <= 150:
                temperatures.append(temp)
        powers = [optional_number(p, 1e6) for p in sorted((self.sys / 'class/power_supply').glob('*/power_now'))[:32]]
        power = sum(p for p in powers if p is not None) if any(p is not None for p in powers) else None
        memory_percent = 100 * used / total_mem if total_mem else None
        self.history.append({'observedMonotonicMs': now * 1000, 'cpuPercent': percent,
                             'memoryPercent': memory_percent, 'powerW': power})
        return {'cpuPercent': percent, 'cpuFrequencyGHz': frequency,
                'cpuTemperatureC': max(temperatures) if temperatures else None,
                'memoryUsedBytes': used, 'memoryTotalBytes': total_mem,
                'memoryPercent': memory_percent, 'powerW': power,
                'uptimeSeconds': float(read_text(self.proc / 'uptime', 256).split()[0]),
                'history': list(self.history)}


class NetworkProvider(Provider):
    def __init__(self, options, proc_root='/proc', **_):
        self.proc = Path(proc_root)
        self.interval = bounded_int(options.get('intervalSeconds'), 1, 1, 60)
        self.names = options.get('interfaces', [])
        if not isinstance(self.names, list) or len(self.names) > 64 or any(not isinstance(x, str) for x in self.names):
            raise ValueError('interfaces must be a bounded string array')
        self.history = deque(maxlen=bounded_int(options.get('historySize'), 60, 2, 240))
        self.previous = None

    def sample(self, now):
        counters = {}
        for line in read_text(self.proc / 'net/dev').splitlines()[2:]:
            if ':' not in line:
                continue
            name, raw = line.split(':', 1)
            name, fields = name.strip(), raw.split()
            if len(counters) >= 64:
                break
            if self.names and name not in self.names or not self.names and name == 'lo':
                continue
            counters[name] = (int(fields[0]), int(fields[8]))
        interfaces = []
        elapsed = now - self.previous[0] if self.previous else 0
        valid = 0 < elapsed <= self.interval * 3
        for name, (rx, tx) in sorted(counters.items()):
            previous = self.previous[1].get(name) if self.previous else None
            rates = ((rx - previous[0]) / elapsed, (tx - previous[1]) / elapsed) if valid and previous and rx >= previous[0] and tx >= previous[1] else (None, None)
            interfaces.append({'name': name, 'rxBytesPerSecond': rates[0], 'txBytesPerSecond': rates[1]})
        self.previous = now, counters
        complete = bool(interfaces) and all(x['rxBytesPerSecond'] is not None for x in interfaces)
        rx = sum(x['rxBytesPerSecond'] for x in interfaces) if complete else None
        tx = sum(x['txBytesPerSecond'] for x in interfaces) if complete else None
        self.history.append({'observedMonotonicMs': now * 1000, 'rxBytesPerSecond': rx, 'txBytesPerSecond': tx})
        return {'interfaces': interfaces, 'rxBytesPerSecond': rx, 'txBytesPerSecond': tx, 'history': list(self.history)}


class FilesProvider(Provider):
    interval = 10
    asynchronous = True

    def __init__(self, options, **_):
        path = options.get('directory')
        if not isinstance(path, str) or not path:
            raise ValueError('Configure a directory path')
        self.path = Path(path).expanduser()
        self.limit = bounded_int(options.get('maxEntries'), 80, 1, 256)
        self.show_hidden = options.get('showHidden', False)

    def sample(self, now):
        entries = []
        inspected = 0
        with os.scandir(self.path) as directory:
            for entry in directory:
                inspected += 1
                if inspected > 2048:
                    break
                if not self.show_hidden and entry.name.startswith('.'):
                    continue
                try:
                    stat = entry.stat(follow_symlinks=False)
                    entries.append({'name': entry.name[:1024], 'path': entry.path[:4096],
                                    'isDirectory': entry.is_dir(follow_symlinks=False),
                                    'sizeBytes': stat.st_size, 'modifiedMs': stat.st_mtime * 1000})
                except OSError:
                    continue
                if len(entries) >= self.limit:
                    break
        entries.sort(key=lambda x: (not x['isDirectory'], x['name'].casefold()))
        return {'path': str(self.path), 'entries': entries, 'truncated': len(entries) == self.limit or inspected > 2048}


class CalendarProvider(Provider):
    """Observe the existing calendar cache without creating or migrating a database."""
    interval = 30
    asynchronous = True

    def __init__(self, options, **_):
        path = options.get('path')
        if not isinstance(path, str) or not path:
            raise ValueError('Configure an existing calendar path')
        self.path = Path(path).expanduser()
        self.limit = bounded_int(options.get('maxEvents'), 100, 1, 256)
        self.days = bounded_int(options.get('daysAhead'), 31, 1, 366)

    def sample(self, now):
        current = datetime.now(timezone.utc)
        start = current.replace(hour=0, minute=0, second=0, microsecond=0).isoformat().replace('+00:00', 'Z')
        end = (current + timedelta(days=self.days)).isoformat().replace('+00:00', 'Z')
        # mode=ro refuses missing files. query_only also guards accidental later changes.
        uri = self.path.resolve().as_uri() + '?mode=ro'
        db = sqlite3.connect(uri, uri=True, timeout=.2)
        try:
            db.execute('PRAGMA query_only=ON')
            db.set_progress_handler(lambda: 1 if time.monotonic() > deadline else 0, 1000)
            deadline = time.monotonic() + .5
            db.row_factory = sqlite3.Row
            rows = db.execute('''SELECT e.event_id,e.title,e.start_value,e.end_value,e.start_kind,
                e.fetched_at_ms,c.id AS calendar_id,c.summary,c.background
                FROM events e JOIN calendars c ON c.id=e.calendar_id
                WHERE c.selected=1 AND e.status!='cancelled' AND e.start_value < ?
                AND e.end_value > ? ORDER BY e.start_value LIMIT ?''', (end, start, self.limit + 1)).fetchall()
            events = [{'id': str(row['event_id'])[:1024], 'title': str(row['title'])[:4096],
                       'start': str(row['start_value'])[:128], 'end': str(row['end_value'])[:128],
                       'allDay': row['start_kind'] == 'all_day', 'calendar': str(row['summary'])[:4096],
                       'calendarId': str(row['calendar_id'])[:1024], 'color': str(row['background'] or '')[:64],
                       'sourceObservedMs': row['fetched_at_ms']} for row in rows[:self.limit]]
            revision = db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()
            return {'epochMs': current.timestamp() * 1000, 'events': events, 'truncated': len(rows) > self.limit,
                    'sourcePath': str(self.path), 'sourceRevision': str(revision[0]) if revision else '',
                    'sourceModifiedMs': self.path.stat().st_mtime * 1000}
        finally:
            db.close()


class WeatherProvider(Provider):
    interval = 600
    asynchronous = True

    def __init__(self, options, http_open=None, **_):
        if options.get('provider', 'open-meteo') != 'open-meteo':
            raise ValueError('Unsupported weather provider')
        self.latitude, self.longitude = options.get('latitude'), options.get('longitude')
        for value, limit in ((self.latitude, 90), (self.longitude, 180)):
            if type(value) not in (int, float) or not math.isfinite(value) or not -limit <= value <= limit:
                raise ValueError('Weather requires explicit latitude and longitude')
        self.interval = bounded_int(options.get('intervalSeconds'), 600, 300, 86400)
        self.http_open = http_open or urllib.request.urlopen
        self.cancelled = threading.Event()

    def sample(self, now):
        # Verified against https://open-meteo.com/en/docs on 2026-10-18.
        query = urllib.parse.urlencode({'latitude': self.latitude, 'longitude': self.longitude,
            'current': 'temperature_2m,weather_code,is_day,wind_speed_10m', 'timezone': 'UTC',
            'temperature_unit': 'celsius', 'wind_speed_unit': 'kmh'})
        request = urllib.request.Request('https://api.open-meteo.com/v1/forecast?' + query,
                                         headers={'User-Agent': 'BloxWidgets/1'})
        deadline = time.monotonic() + 8
        with self.http_open(request, timeout=5) as response:
            chunks, size = [], 0
            while size <= 65536:
                if self.cancelled.is_set():
                    raise InterruptedError('Weather request cancelled')
                if time.monotonic() > deadline:
                    raise TimeoutError('Weather request timed out')
                chunk = response.read1(min(4096, 65537 - size)) if hasattr(response, 'read1') else response.read(65537 - size)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            raw = b''.join(chunks)
        if len(raw) > 65536:
            raise ValueError('Weather response exceeds limit')
        result = json.loads(raw)
        value = result['current']
        for field in ('temperature_2m', 'weather_code', 'is_day', 'wind_speed_10m'):
            if type(value[field]) not in (int, float) or not math.isfinite(value[field]):
                raise ValueError('Invalid weather observation')
        if self.cancelled.is_set():
            raise InterruptedError('Weather request cancelled')
        return {'temperatureC': value['temperature_2m'], 'weatherCode': value['weather_code'],
                'isDay': bool(value['is_day']), 'windSpeedKph': value['wind_speed_10m'],
                'sourceTime': str(value['time'])[:128], 'latitude': self.latitude,
                'longitude': self.longitude, 'attribution': 'Open-Meteo'}


    def close(self):
        self.cancelled.set()


PROVIDERS = {'clock': ClockProvider, 'system': SystemProvider, 'network': NetworkProvider,
             'files': FilesProvider, 'calendar': CalendarProvider, 'weather': WeatherProvider}


def create_provider(name, options, **dependencies):
    from .model import validate_settings
    options = validate_settings(name, options)
    if name == 'command':
        from .command import CommandOutput
        return CommandOutput(options, **dependencies)
    if name == 'terminal':
        from .terminal import TerminalSession
        return TerminalSession(options, dependencies.pop('generation', 0))
    if name not in PROVIDERS:
        raise ValueError('Unsupported broker provider')
    return PROVIDERS[name](options, **dependencies)
