import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    required property string scriptRoot
    readonly property int refreshTimeoutMs: 20000
    property bool automaticRefresh: true
    property var events: []
    property var calendars: []
    property bool loading: false
    property bool refreshing: false
    property string error: ""
    property int revision: 0
    property var activeScreen: null
    property bool detailsOpen: false
    property bool editorOpen: false
    property bool confirmDeleteOpen: false
    property bool deleteStandalone: false
    property bool eventMenuOpen: false
    property bool childPositionReady: false
    property string popoutScreenName: ""
    property rect popoutRect: Qt.rect(0, 0, 0, 0)
    property string deleteScope: "instance"
    property var activeEvent: null
    property var deleteEvent: null
    property date selectedDate: new Date()
    property date rangeDate: selectedDate
    readonly property bool childWindowOpen: detailsOpen || editorOpen || confirmDeleteOpen || eventMenuOpen
    property string pendingCommand: ""
    property var pendingPayload: null
    property var popoutNotice: null
    property var editorNotice: null
    property var deleteNotice: null
    property bool editorSaving: false
    property bool deleteSaving: false
    property var coverage: []
    property bool coverageComplete: false
    property double coverageOldestMs: 0
    property var commandQueue: []
    property var activeCommand: null
    property bool ignoreMutatorExit: false
    property var timedOutCommand: null
    property var pendingReconcileRetries: []
    property var refreshedAt: ({
    })
    property var pendingSnapshotDate: null
    property double lastHoverRefreshMs: 0

    function defaultCalendar() {
        var writable = calendars.filter(function(c) {
            return c.write_allowed;
        });
        return writable.filter(function(c) {
            return c.primary;
        })[0] || writable[0] || null;
    }

    function iso(date) {
        return Qt.formatDate(date, "yyyy-MM-dd");
    }

    function retainedRange(date) {
        return {
            "start": new Date(date.getFullYear(), date.getMonth() - 1, 1).toISOString(),
            "end": new Date(date.getFullYear(), date.getMonth() + 2, 1).toISOString()
        };
    }

    function startOfDay(date) {
        return new Date(date.getFullYear(), date.getMonth(), date.getDate());
    }

    function endOfDay(date) {
        return new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
    }

    function monthRange(date) {
        return {
            "start": new Date(date.getFullYear(), date.getMonth(), 1),
            "end": new Date(date.getFullYear(), date.getMonth() + 1, 1)
        };
    }

    function rangeKey(start, end) {
        return start.toISOString() + "/" + end.toISOString();
    }

    function createId() {
        var value = Date.now().toString(16);
        while (value.length < 32)value += Math.floor(Math.random() * 16).toString(16)
        return value.slice(0, 32);
    }

    function eventByKey(key) {
        return events.filter(function(item) {
            return item.key === key;
        })[0] || null;
    }

    function replaceEvent(event) {
        if (!event)
            return ;

        var found = false, next = events.map(function(item) {
            if (item.key === event.key) {
                found = true;
                return event;
            }
            return item;
        });
        if (!found)
            next.push(event);

        events = next;
    }

    function settledEvent(event) {
        if (!event)
            return null;

        var result = Object.assign({
        }, event);
        result.pending = false;
        result.busy = false;
        return result;
    }

    function clearNotice(surface) {
        if (surface === "editor")
            editorNotice = null;
        else if (surface === "delete")
            deleteNotice = null;
        else
            popoutNotice = null;
        error = "";
    }

    function failureHeading(item, errorObject) {
        var command = item.command;
        var code = errorObject && errorObject.code || "provider_error";
        if (code === "partial_mutation")
            return "Google Calendar only completed part of the change";

        if (code === "not_applied")
            return "Google Calendar did not save the change";

        if (code === "reconciliation_failed")
            return "Couldn’t confirm what Google Calendar saved";

        if (code === "auth_required")
            return "Google Calendar needs you to sign in";

        if (code === "etag_conflict")
            return "This event changed in Google Calendar";

        if (code === "permission_denied")
            return "Google Calendar refused this change";

        if (code === "rate_limited")
            return "Google Calendar is busy";

        if (code === "timeout")
            return command === "refresh" ? "Calendar refresh timed out" : "The calendar request timed out";

        if (code === "provider_unavailable")
            return "Google Calendar is unavailable";

        if (command === "create")
            return "Event wasn’t created";

        if (command === "delete")
            return "Event wasn’t deleted";

        if (command === "refresh")
            return "Couldn’t refresh Google Calendar";

        if (item.actionLabel === "colour")
            return "Couldn’t change the event colour";

        if (item.actionLabel === "move" || item.actionLabel === "resize")
            return "Couldn’t change the event time";

        return "Couldn’t update the event";
    }

    function failureDetail(item, errorObject) {
        var command = item.command;
        var code = errorObject && errorObject.code || "provider_error";
        if (code === "partial_mutation")
            return "Refresh to see the result before trying another change.";

        if (code === "not_applied")
            return "The event is unchanged. You can try again.";

        if (code === "reconciliation_failed")
            return "It will retry when the connection returns. You can also retry now.";

        if (code === "auth_required")
            return "Run gcalcli once, then return and try again.";

        if (code === "etag_conflict")
            return "Reload the latest version before saving your changes.";

        if (code === "permission_denied")
            return "Check that this calendar still allows changes.";

        if (code === "rate_limited")
            return "Wait a moment, then try again.";

        if (command === "refresh")
            return "Showing saved events from the last successful refresh.";

        if (code === "provider_unavailable" || code === "timeout")
            return "Your local data is unchanged.";

        if (command === "create")
            return "Your details are still here. Check the connection, then try again.";

        if (command === "delete")
            return "The event is unchanged. You can try again.";

        if (item.actionLabel === "colour")
            return "The previous colour has been restored.";

        if (item.actionLabel === "move" || item.actionLabel === "resize")
            return "The previous time has been restored.";

        return "The previous value has been restored.";
    }

    function open(date, screen) {
        selectedDate = date;
        activeScreen = screen;
        snapshot();
    }

    function snapshot(date) {
        if (snapshotProcess.running) {
            pendingSnapshotDate = date || rangeDate;
            return ;
        }

        rangeDate = date || selectedDate;
        var range = retainedRange(rangeDate);
        loading = events.length === 0;
        error = "";
        snapshotProcess.command = [root.scriptRoot + "/calendar/calendar_adapter.py", "snapshot", "--start", range.start, "--end", range.end];
        snapshotProcess.running = true;
    }

    function requestRefresh(start, end, reason, maxAgeMs, priority, calendarIds) {
        if (!(start instanceof Date))
            start = new Date(start);

        if (!(end instanceof Date))
            end = new Date(end);

        if (end <= start)
            return false;

        var ids = calendarIds || [], key = rangeKey(start, end) + (ids.length ? "|" + ids.slice().sort().join(",") : ""), now = Date.now(), age = maxAgeMs === undefined ? 0 : maxAgeMs;
        if (age > 0 && refreshedAt[key] && now - refreshedAt[key] < age)
            return false;

        if (activeCommand && activeCommand.command === "refresh" && activeCommand.key === key)
            return false;

        if (commandQueue.some(function(item) {
            return item.command === "refresh" && item.key === key;
        }))
            return false;

        var args = ["--start", start.toISOString(), "--end", end.toISOString()];
        for (var i = 0; i < ids.length; ++i) args.push("--calendar-id", ids[i])
        enqueue({
            "command": "refresh",
            "payload": null,
            "args": args,
            "key": key,
            "calendarIds": ids,
            "reason": reason || "manual",
            "surface": "popout"
        }, priority === true);
        return true;
    }

    function refresh(force) {
        var range = retainedRange(rangeDate);
        return requestRefresh(new Date(range.start), new Date(range.end), "manual", force ? 0 : 3.6e+06, false);
    }

    function refreshOnHover() {
        var now = Date.now();
        if (now - lastHoverRefreshMs < 30000)
            return ;

        lastHoverRefreshMs = now;
        var today = new Date(), month = monthRange(today);
        requestRefresh(startOfDay(today), endOfDay(today), "hover", 30000, false);
        requestRefresh(month.start, month.end, "hover", 30000, false);
    }

    function refreshHourlyRanges() {
        var now = new Date(), tomorrow = endOfDay(now), weekEnd = new Date(tomorrow);
        weekEnd.setDate(weekEnd.getDate() + ((7 - weekEnd.getDay()) % 7));
        if (weekEnd > tomorrow)
            requestRefresh(tomorrow, weekEnd, "hourly", 3.6e+06, false);

        var next = monthRange(new Date(now.getFullYear(), now.getMonth() + 1, 1));
        requestRefresh(next.start, next.end, "hourly", 3.6e+06, false);
    }

    function refreshDailyRanges() {
        var now = new Date(), monday = startOfDay(now);
        monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7));
        var nextWeek = new Date(monday);
        nextWeek.setDate(nextWeek.getDate() + 7);
        var twoWeeks = new Date(monday);
        twoWeeks.setDate(twoWeeks.getDate() + 14);
        requestRefresh(nextWeek, twoWeeks, "daily", 8.64e+07, false);
        var later = new Date(now.getFullYear(), now.getMonth() + 2, 1), yearEnd = new Date(now.getFullYear() + 1, 0, 1);
        if (later < yearEnd)
            requestRefresh(later, yearEnd, "daily", 8.64e+07, false);

    }

    function refreshViewedDate(date, viewKind) {
        var range = viewKind === "month" ? monthRange(date) : {
            "start": startOfDay(date),
            "end": endOfDay(date)
        };
        requestRefresh(range.start, range.end, "navigation", 300000, false);
    }

    function finishNavigation(date, viewKind) {
        refreshViewedDate(date, viewKind);
    }

    function refreshAfterMutation(eventOrDate) {
        var date = eventOrDate instanceof Date ? eventOrDate : eventOrDate && eventOrDate.time && eventOrDate.time.kind === "timed" ? new Date(eventOrDate.time.start_ms) : selectedDate;
        requestRefresh(startOfDay(date), endOfDay(date), "mutation", 0, true);
        var month = monthRange(date);
        requestRefresh(month.start, month.end, "mutation", 0, true);
    }

    function showDetails(event) {
        cancelDelete();
        eventMenuOpen = false;
        if (!detailsOpen)
            childPositionReady = false;

        activeEvent = event;
        detailsOpen = true;
        editorOpen = false;
    }

    function editEvent(event) {
        cancelDelete();
        eventMenuOpen = false;
        childPositionReady = false;
        activeEvent = event;
        detailsOpen = false;
        editorOpen = true;
    }

    function createEvent(date, startHour, endHour) {
        var calendar = defaultCalendar();
        if (!calendar) {
            error = "No writable calendar is allowed.";
            popoutNotice = {
                "operation": "create",
                "message": error,
                "severity": "error",
                "phase": "failed",
                "retryable": false
            };
            return false;
        }
        cancelDelete();
        eventMenuOpen = false;
        activeEvent = {
            "key": "local:draft",
            "id": "",
            "create_id": createId(),
            "etag": "",
            "title": "",
            "description": "",
            "location": "",
            "event_type": "default",
            "locked": false,
            "calendar": calendar,
            "colour": {
                "event_id": "",
                "display": calendar.colour,
                "calendar_fallback": calendar.colour
            },
            "recurrence": {
                "master_id": "",
                "summary": "",
                "custom": false
            },
            "time": {
                "kind": "timed",
                "start_ms": dayTime(date, startHour).getTime(),
                "end_ms": dayTime(date, endHour).getTime(),
                "start_zone": calendar.time_zone || "",
                "end_zone": calendar.time_zone || ""
            },
            "can_edit": true,
            "capability_reason": "",
            "cache": {
                "stale": false,
                "operation": "draft"
            }
        };
        childPositionReady = false;
        detailsOpen = false;
        editorOpen = true;
        return true;
    }

    function closeChildren(force) {
        if (!force && (editorSaving || deleteSaving))
            return false;

        detailsOpen = false;
        editorOpen = false;
        confirmDeleteOpen = false;
        deleteStandalone = false;
        eventMenuOpen = false;
        activeEvent = null;
        deleteEvent = null;
        editorNotice = null;
        deleteNotice = null;
        return true;
    }

    function write(command, payload, optimisticEvent, refreshDate, surface, eventKey, successClose, actionLabel) {
        if (eventKey && eventByKey(eventKey) && eventByKey(eventKey).busy)
            return false;

        clearNotice(surface);
        var rollback = eventKey ? eventByKey(eventKey) : null;
        if (optimisticEvent) {
            optimisticEvent.busy = true;
            replaceEvent(optimisticEvent);
        } else if (rollback) {
            var busyEvent = Object.assign({
            }, rollback);
            busyEvent.busy = true;
            replaceEvent(busyEvent);
        }
        var item = {
            "command": command,
            "payload": payload,
            "args": [],
            "rollback": rollback,
            "optimistic": optimisticEvent || null,
            "refreshDate": refreshDate || null,
            "surface": surface || "popout",
            "eventKey": eventKey || "",
            "successClose": successClose || "",
            "actionLabel": actionLabel || "update"
        };
        if (surface === "editor")
            editorSaving = true;
        else if (surface === "delete")
            deleteSaving = true;
        enqueue(item, true);
        return true;
    }

    function enqueue(item, priority) {
        var next = commandQueue.slice();
        if (priority)
            next.unshift(item);
        else
            next.push(item);
        commandQueue = next;
        startNext();
        updateRefreshing();
    }

    function updateRefreshing() {
        refreshing = (activeCommand && activeCommand.command === "refresh") || commandQueue.some(function(item) {
            return item.command === "refresh";
        });
        if (!activeCommand && !commandQueue.length) {
            pendingCommand = "";
            pendingPayload = null;
        }
    }

    function startNext() {
        if (mutator.running || !commandQueue.length)
            return ;

        var next = commandQueue[0];
        commandQueue = commandQueue.slice(1);
        activeCommand = next;
        pendingCommand = next.command;
        pendingPayload = next.payload;
        mutator.command = [root.scriptRoot + "/calendar/calendar_adapter.py", next.command].concat(next.args);
        mutator.running = true;
        processTimeout.restart();
        updateRefreshing();
    }

    function saveEvent(title, description, location, chosenDate, chosenStart, chosenEnd, colourId, allDay, calendarId, recurrenceRule) {
        if (editorSaving)
            return false;

        if (!title.trim()) {
            editorNotice = {
                "message": "Add an event title.",
                "retryable": false,
                "code": "invalid_request"
            };
            return false;
        }
        var item = activeEvent, calendar = calendars.filter(function(c) {
            return c.id === calendarId;
        })[0] || item.calendar || defaultCalendar();
        if (!calendar) {
            editorNotice = {
                "message": "No writable calendar is allowed.",
                "retryable": false,
                "code": "invalid_request"
            };
            return false;
        }
        var sourceStart = chosenStart || new Date(item.time.start_ms), sourceEnd = chosenEnd || new Date(item.time.end_ms), date = chosenDate || sourceStart;
        var start = new Date(date.getFullYear(), date.getMonth(), date.getDate(), sourceStart.getHours(), sourceStart.getMinutes());
        var end = new Date(date.getFullYear(), date.getMonth(), date.getDate(), sourceEnd.getHours(), sourceEnd.getMinutes());
        if (end <= start)
            end.setDate(end.getDate() + 1);

        var changes = {
            "summary": title.trim(),
            "description": description,
            "location": location
        };
        if (allDay) {
            changes.start = {
                "date": iso(date)
            };
            var next = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1);
            changes.end = {
                "date": iso(next)
            };
        } else {
            changes.start = {
                "dateTime": start.toISOString()
            };
            changes.end = {
                "dateTime": end.toISOString()
            };
            if (item.time.start_zone)
                changes.start.timeZone = item.time.start_zone;

            if (item.time.end_zone)
                changes.end.timeZone = item.time.end_zone;

        }
        if (colourId !== undefined)
            changes.colorId = colourId || null;

        if (recurrenceRule)
            changes.recurrence = [recurrenceRule];
        else if (recurrenceRule === "")
            changes.recurrence = [];
        var queued = false;
        if (item.id) {
            if (calendar.id !== item.calendar.id)
                queued = write("move", {
                "calendar_id": item.calendar.id,
                "destination_id": calendar.id,
                "event_id": item.id,
                "etag": item.etag,
                "changes": changes
            }, null, start, "editor", item.key, "editor", "edit");
            else
                queued = write("update", {
                "calendar_id": calendar.id,
                "event_id": item.id,
                "etag": item.etag,
                "changes": changes
            }, null, start, "editor", item.key, "editor", "edit");
        } else {
            queued = write("create", {
                "calendar_id": calendar.id,
                "create_id": item.create_id || createId(),
                "event": changes
            }, null, start, "editor", "", "editor", "create");
        }
        return queued;
    }

    function requestDelete(event, openHost) {
        if (event && event.can_edit && !event.busy) {
            activeEvent = event;
            deleteEvent = event;
            deleteScope = "instance";
            deleteStandalone = openHost === false;
            eventMenuOpen = false;
            if (deleteStandalone) {
                detailsOpen = false;
                editorOpen = false;
                childPositionReady = false;
            } else if (!detailsOpen && !editorOpen) {
                childPositionReady = false;
                detailsOpen = true;
            }
            confirmDeleteOpen = true;
        }
    }

    function cancelDelete() {
        if (deleteSaving)
            return ;

        confirmDeleteOpen = false;
        deleteStandalone = false;
        deleteEvent = null;
    }

    function confirmDelete() {
        if (deleteSaving)
            return ;

        var event = deleteEvent;
        if (event && event.can_edit)
            write("delete", {
                "calendar_id": event.calendar.id,
                "event_id": event.id,
                "etag": event.etag,
                "scope": deleteScope,
                "master_id": event.recurrence ? event.recurrence.master_id : "",
                "original_start": event.recurrence ? event.recurrence.original_start : null
            }, null, event.time && event.time.kind === "timed" ? new Date(event.time.start_ms) : selectedDate, "delete", event.key, "delete", "delete");

    }

    function dayTime(date, hour) {
        return new Date(date.getFullYear(), date.getMonth(), date.getDate(), Math.floor(hour), Math.round((hour % 1) * 60));
    }

    function moveEventTime(event, date, startHour) {
        if (!event.can_edit || event.busy || event.time.kind !== "timed")
            return ;

        var duration = event.time.end_ms - event.time.start_ms, start = dayTime(date, startHour);
        var candidate = Object.assign({
        }, event), time = Object.assign({
        }, event.time);
        time.start_ms = start.getTime();
        time.end_ms = start.getTime() + duration;
        candidate.time = time;
        candidate.pending = true;
        write("update", {
            "calendar_id": event.calendar.id,
            "event_id": event.id,
            "etag": event.etag,
            "changes": {
                "start": {
                    "dateTime": start.toISOString(),
                    "timeZone": event.time.start_zone
                },
                "end": {
                    "dateTime": new Date(start.getTime() + duration).toISOString(),
                    "timeZone": event.time.end_zone
                }
            }
        }, candidate, start, "event", event.key, "", "move");
    }

    function resizeEventTime(event, date, endHour) {
        if (!event.can_edit || event.busy || event.time.kind !== "timed")
            return ;

        var end = dayTime(date, endHour);
        var candidate = Object.assign({
        }, event), time = Object.assign({
        }, event.time);
        time.end_ms = end.getTime();
        candidate.time = time;
        candidate.pending = true;
        write("update", {
            "calendar_id": event.calendar.id,
            "event_id": event.id,
            "etag": event.etag,
            "changes": {
                "end": {
                    "dateTime": end.toISOString(),
                    "timeZone": event.time.end_zone
                }
            }
        }, candidate, date, "event", event.key, "", "resize");
    }

    function changeEventColour(event, colourId) {
        if (!event || !event.can_edit || event.busy)
            return false;

        var palette = {
            "9": "#5484ed",
            "3": "#dbadff",
            "7": "#46d6db",
            "5": "#fbd75b",
            "11": "#dc2127",
            "1": "#a4bdfc",
            "10": "#51b749",
            "2": "#7ae7bf",
            "6": "#ffb878",
            "4": "#ff887c"
        };
        var candidate = Object.assign({
        }, event), colour = Object.assign({
        }, event.colour);
        colour.event_id = colourId;
        colour.display = palette[colourId] || colour.display;
        candidate.colour = colour;
        candidate.pending = true;
        return write("update", {
            "calendar_id": event.calendar.id,
            "event_id": event.id,
            "etag": event.etag,
            "changes": {
                "colorId": colourId
            }
        }, candidate, event.time && event.time.kind === "timed" ? new Date(event.time.start_ms) : selectedDate, "event", event.key, "", "colour");
    }

    function parseOutput(text) {
        try {
            var response = JSON.parse(text);
            if (!response || typeof response.ok !== "boolean")
                throw new Error("missing ok field");

            return {
                "valid": true,
                "response": response
            };
        } catch (e) {
            return {
                "valid": false,
                "error": {
                    "code": "invalid_response",
                    "message": "Calendar returned invalid data: " + e,
                    "retryable": true,
                    "details": {
                        "uncertain": true
                    }
                }
            };
        }
    }

    function eventOverlapsRange(event, start, end) {
        if (event.time.kind === "all_day")
            return event.time.start_date < Qt.formatDate(end, "yyyy-MM-dd") && event.time.end_date_exclusive > Qt.formatDate(start, "yyyy-MM-dd");

        return event.time.start_ms < end.getTime() && event.time.end_ms > start.getTime();
    }

    function applyData(response, replaceRange, preserveEvents) {
        var data = response.data || {
        };
        revision = response.revision;
        if (data.events && !preserveEvents) {
            var providerEvents = data.events.slice();
            if (replaceRange) {
                var rangeStart = new Date(replaceRange.start), rangeEnd = new Date(replaceRange.end);
                var refreshedIds = data.refreshed_calendar_ids || replaceRange.calendarIds || [];
                providerEvents = providerEvents.filter(function(event) {
                    return refreshedIds.indexOf(event.calendar && event.calendar.id) !== -1;
                });
                providerEvents = events.filter(function(event) {
                    var calendarId = event.calendar && event.calendar.id;
                    var sliceWasReplaced = refreshedIds.indexOf(calendarId) !== -1;
                    return !sliceWasReplaced || !eventOverlapsRange(event, rangeStart, rangeEnd);
                }).concat(providerEvents);
            }
            for (var pendingIndex = 0; pendingIndex < events.length; ++pendingIndex) {
                var pendingEvent = events[pendingIndex];
                if (!pendingEvent.busy)
                    continue;

                var replaced = false;
                providerEvents = providerEvents.map(function(providerEvent) {
                    if (providerEvent.key === pendingEvent.key) {
                        replaced = true;
                        return pendingEvent;
                    }
                    return providerEvent;
                });
                if (!replaced)
                    providerEvents.push(pendingEvent);

            }
            if (modelSignature(events) !== modelSignature(providerEvents))
                events = providerEvents;

        }
        if (data.calendars && JSON.stringify(calendars) !== JSON.stringify(data.calendars))
            calendars = data.calendars;

        if (data.coverage)
            coverage = data.coverage;

        if (data.coverage_complete !== undefined)
            coverageComplete = data.coverage_complete;

        if (data.coverage_oldest_ms !== undefined)
            coverageOldestMs = data.coverage_oldest_ms;

        if (data.range_freshness) {
            var grouped = {
            }, calendarCount = (data.calendars || calendars).length;
            for (var i = 0; i < data.range_freshness.length; ++i) {
                var item = data.range_freshness[i], key = rangeKey(new Date(item.start_utc), new Date(item.end_utc));
                if (!grouped[key])
                    grouped[key] = {
                    "calendars": {
                    },
                    "oldest": item.refreshed_at_ms
                };

                grouped[key].calendars[item.calendar_id] = true;
                grouped[key].oldest = Math.min(grouped[key].oldest, item.refreshed_at_ms);
            }
            var fresh = Object.assign({
            }, refreshedAt);
            for (var range in grouped) {
                if (Object.keys(grouped[range].calendars).length >= calendarCount)
                    fresh[range] = grouped[range].oldest;

            }
            refreshedAt = fresh;
        }
    }

    function restoreItem(item) {
        if (item && item.rollback) {
            replaceEvent(settledEvent(item.rollback));
        } else if (item && item.eventKey) {
            var current = eventByKey(item.eventKey);
            if (current)
                replaceEvent(settledEvent(current));

        }
    }

    function finishSurface(item) {
        if (!item)
            return ;

        if (item.surface === "editor")
            editorSaving = false;
        else if (item.surface === "delete")
            deleteSaving = false;
    }

    function setFailure(item, errorObject, retryItem) {
        var heading = failureHeading(item, errorObject);
        var detail = failureDetail(item, errorObject);
        var notice = {
            "operation": item.command,
            "heading": heading,
            "detail": detail,
            "message": heading + ". " + detail,
            "code": errorObject.code || "provider_error",
            "retryable": errorObject.retryable === true,
            "retryItem": retryItem || null,
            "severity": "error",
            "phase": "failed"
        };
        error = notice.message;
        if (item.surface === "editor")
            editorNotice = notice;
        else if (item.surface === "delete")
            deleteNotice = notice;
        else
            popoutNotice = notice;
    }

    function beginReconcile(item) {
        enqueue({
            "command": "reconcile",
            "payload": {
                "operation": item.command,
                "request": item.payload
            },
            "args": [],
            "surface": item.surface,
            "eventKey": item.eventKey,
            "original": item,
            "refreshDate": item.refreshDate
        }, true);
    }

    function scheduleReconcileRetry(item) {
        if (!item)
            return ;

        var retry = Object.assign({
        }, item);
        retry.reconcileAttempt = (retry.reconcileAttempt || 0) + 1;
        retry.nextRetryAt = Date.now() + Math.min(60000, 5000 * Math.pow(2, retry.reconcileAttempt - 1));
        var key = reconcileRetryKey(retry);
        pendingReconcileRetries = pendingReconcileRetries.filter(function(existing) {
            return reconcileRetryKey(existing) !== key;
        }).concat([retry]);
    }

    function reconcileRetryKey(item) {
        var original = item && (item.original || item);
        return original ? original.eventKey || original.command + ":" + (original.payload && original.payload.create_id || "") : "";
    }

    function cancelReconcileRetry(item) {
        if (item) {
            var key = reconcileRetryKey(item);
            pendingReconcileRetries = pendingReconcileRetries.filter(function(existing) {
                return reconcileRetryKey(existing) !== key;
            });
        } else {
            pendingReconcileRetries = [];
        }
        if (!pendingReconcileRetries.length && connectivityProbe.running)
            connectivityProbe.running = false;

    }

    function resumeReconcile(item) {
        cancelReconcileRetry(item);
        if (!item)
            return ;

        if (item.surface === "editor")
            editorSaving = true;
        else if (item.surface === "delete")
            deleteSaving = true;
        enqueue(item, true);
    }

    function finishSuccess(item, data) {
        if (data && data.event) {
            if (item.eventKey && item.eventKey !== data.event.key)
                events = events.filter(function(event) {
                return event.key !== item.eventKey;
            });

            replaceEvent(settledEvent(data.event));
        } else if (item.command === "delete" && item.eventKey) {
            events = events.filter(function(event) {
                return event.key !== item.eventKey;
            });
        } else if (item.eventKey) {
            var current = eventByKey(item.eventKey);
            if (current)
                replaceEvent(settledEvent(current));

        }
        finishSurface(item);
        clearNotice(item.surface);
        if (item.successClose)
            closeChildren(true);

        refreshAfterMutation(item.refreshDate || selectedDate);
    }

    function handleRefreshSuccess(item, response) {
        applyData(response, {
            "start": item.args[1],
            "end": item.args[3],
            "calendarIds": item.calendarIds || []
        }, true);
        snapshot(rangeDate);
        var failures = response.data && response.data.partial_failures || [];
        if (!failures.length) {
            if (popoutNotice && popoutNotice.operation === "refresh")
                popoutNotice = null;

            var next = Object.assign({
            }, refreshedAt);
            next[item.key] = Date.now();
            refreshedAt = next;
            error = "";
            return ;
        }
        var names = failures.map(function(failure) {
            return failure.calendar_summary || failure.calendar_id;
        });
        var failedIds = failures.map(function(failure) {
            return failure.calendar_id;
        });
        var stale = Object.assign({
        }, refreshedAt);
        delete stale[rangeKey(new Date(item.args[1]), new Date(item.args[3]))];
        refreshedAt = stale;
        var retry = Object.assign({
        }, item);
        retry.args = ["--start", item.args[1], "--end", item.args[3]];
        for (var i = 0; i < failedIds.length; ++i) retry.args.push("--calendar-id", failedIds[i])
        retry.calendarIds = failedIds;
        retry.key = rangeKey(new Date(item.args[1]), new Date(item.args[3])) + "|" + failedIds.slice().sort().join(",");
        popoutNotice = {
            "operation": "refresh",
            "heading": names.length === 1 ? names[0] + " is out of date" : names.length + " calendars are out of date",
            "detail": names.join(", ") + (names.length === 1 ? " still shows" : " still show") + " saved events.",
            "message": names.join(", ") + (names.length === 1 ? " is" : " are") + " showing saved events.",
            "severity": "warning",
            "phase": "failed",
            "retryable": true,
            "retryItem": retry
        };
        error = popoutNotice.message;
    }

    function handleCommandResult(item, code, stdoutText, stderrText) {
        if (!item)
            return ;

        var parsed = parseOutput(stdoutText), response = parsed.valid ? parsed.response : null;
        if (item.command === "refresh") {
            if (parsed.valid && response.ok)
                handleRefreshSuccess(item, response);
            else
                setFailure(item, parsed.valid ? response.error : parsed.error, item);
            return ;
        }
        if (item.command === "reconcile") {
            var original = item.original;
            if (!parsed.valid || !response.ok) {
                var reconciliationError = parsed.valid ? response.error : parsed.error;
                var retryableReconciliation = reconciliationError.retryable === true;
                reconciliationError = Object.assign({
                }, reconciliationError, {
                    "code": retryableReconciliation ? "reconciliation_failed" : reconciliationError.code || "reconciliation_failed",
                    "message": "Couldn’t confirm what Google Calendar saved.",
                    "retryable": retryableReconciliation
                });
                finishSurface(original);
                setFailure(original, reconciliationError, item);
                if (retryableReconciliation)
                    scheduleReconcileRetry(item);

                return ;
            }
            cancelReconcileRetry(item);
            applyData(response);
            if (response.data.state === "applied") {
                finishSuccess(original, response.data);
            } else if (response.data.state === "partial") {
                if (response.data.event)
                    replaceEvent(settledEvent(response.data.event));
                else if (original.eventKey && eventByKey(original.eventKey))
                    replaceEvent(settledEvent(eventByKey(original.eventKey)));
                finishSurface(original);
                refreshAfterMutation(original.refreshDate || selectedDate);
                setFailure(original, {
                    "code": "partial_mutation",
                    "message": "Google Calendar only completed part of the change.",
                    "retryable": false
                }, null);
            } else {
                restoreItem(original);
                finishSurface(original);
                setFailure(original, {
                    "code": "not_applied",
                    "message": "Google Calendar did not save the change.",
                    "retryable": true
                }, original);
            }
            return ;
        }
        if (parsed.valid && response.ok) {
            applyData(response);
            finishSuccess(item, response.data || {
            });
            return ;
        }
        var failure = parsed.valid ? response.error : parsed.error;
        var uncertain = failure && failure.details && failure.details.uncertain;
        if (uncertain || failure.code === "duplicate") {
            beginReconcile(item);
            return ;
        }
        restoreItem(item);
        finishSurface(item);
        if (failure.code === "etag_conflict")
            refreshAfterMutation(item.refreshDate || selectedDate);

        setFailure(item, failure, failure.retryable ? item : null);
    }

    function retryNotice() {
        var item = popoutNotice && popoutNotice.retryItem;
        if (!item)
            return ;

        popoutNotice = null;
        error = "";
        if (item.command === "reconcile") {
            resumeReconcile(item);
            return ;
        }
        if (item.optimistic)
            replaceEvent(item.optimistic);

        enqueue(item, true);
    }

    function retrySurfaceNotice(surface) {
        var notice = surface === "editor" ? editorNotice : deleteNotice;
        var item = notice && notice.retryItem;
        if (!item)
            return ;

        if (surface === "editor")
            editorNotice = null;
        else
            deleteNotice = null;
        if (item.command === "reconcile") {
            resumeReconcile(item);
            return ;
        }
        if (surface === "editor")
            editorSaving = true;
        else
            deleteSaving = true;
        error = "";
        enqueue(item, true);
    }

    function reloadEditorEvent() {
        if (!activeEvent)
            return ;

        var date = activeEvent.time && activeEvent.time.kind === "timed" ? new Date(activeEvent.time.start_ms) : selectedDate;
        editorSaving = false;
        closeChildren(true);
        snapshot(date);
        refreshAfterMutation(date);
    }

    function snapshotResult(text, fallback) {
        var parsed = parseOutput(text);
        if (parsed.valid && parsed.response.ok) {
            applyData(parsed.response);
            if (popoutNotice && popoutNotice.operation === "snapshot")
                popoutNotice = null;

            return true;
        }
        error = fallback || (parsed.valid ? parsed.response.error.message : parsed.error.message);
        popoutNotice = {
            "operation": "snapshot",
            "heading": "Couldn’t load saved calendar data",
            "detail": error,
            "message": error,
            "severity": "error",
            "phase": "failed",
            "retryable": false
        };
        return false;
    }

    function modelSignature(model) {
        return JSON.stringify(model.map(function(e) {
            return {
                "key": e.key,
                "etag": e.etag,
                "title": e.title,
                "description": e.description,
                "location": e.location,
                "time": e.time,
                "colour": e.colour,
                "calendar": e.calendar,
                "recurrence": e.recurrence,
                "can_edit": e.can_edit,
                "pending": e.pending || false,
                "busy": e.busy || false
            };
        }));
    }

    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.automaticRefresh
        triggeredOnStart: true
        onTriggered: root.refreshHourlyRanges()
    }

    Timer {
        interval: 60 * 60 * 1000
        repeat: true
        running: root.automaticRefresh
        triggeredOnStart: true
        onTriggered: root.refreshDailyRanges()
    }

    Timer {
        id: processTimeout

        interval: root.refreshTimeoutMs
        onTriggered: {
            if (mutator.running) {
                root.timedOutCommand = root.activeCommand;
                root.ignoreMutatorExit = true;
                mutator.running = false;
            }
        }
    }

    Timer {
        id: reconnectTimer

        interval: 3000
        repeat: true
        running: root.pendingReconcileRetries.length > 0
        onTriggered: {
            var due = root.pendingReconcileRetries.some(function(item) {
                return Date.now() >= item.nextRetryAt;
            });
            if (!due || mutator.running || connectivityProbe.running)
                return ;

            connectivityProbe.command = ["nmcli", "-t", "-f", "CONNECTIVITY", "general"];
            connectivityProbe.running = true;
        }
    }

    Process {
        id: connectivityProbe

        onExited: function(code) {
            if (code !== 0 || connectivityOutput.text.trim() !== "full")
                return ;

            var due = root.pendingReconcileRetries.filter(function(item) {
                return Date.now() >= item.nextRetryAt;
            }).sort(function(left, right) {
                return left.nextRetryAt - right.nextRetryAt;
            });
            if (due.length)
                root.resumeReconcile(due[0]);

        }

        stdout: StdioCollector {
            id: connectivityOutput
        }

    }

    Process {
        id: snapshotProcess

        onExited: function(code) {
            root.loading = false;
            root.snapshotResult(snapshotOutput.text, "Could not read the calendar cache.");
            if (root.pendingSnapshotDate) {
                var nextDate = root.pendingSnapshotDate;
                root.pendingSnapshotDate = null;
                root.snapshot(nextDate);
            }
        }

        stdout: StdioCollector {
            id: snapshotOutput
        }

        stderr: StdioCollector {
            id: snapshotErrors
        }

    }

    Process {
        id: mutator

        stdinEnabled: true
        onStarted: {
            if (root.pendingPayload)
                write(JSON.stringify(root.pendingPayload) + "\n");

        }
        onExited: function(code) {
            processTimeout.stop();
            var finished = root.activeCommand;
            root.activeCommand = null;
            root.pendingPayload = null;
            if (root.ignoreMutatorExit) {
                var timedOut = root.timedOutCommand;
                root.ignoreMutatorExit = false;
                root.timedOutCommand = null;
                if (timedOut) {
                    if (timedOut.command === "refresh")
                        root.setFailure(timedOut, {
                        "code": "timeout",
                        "message": "Calendar refresh timed out.",
                        "retryable": true
                    }, timedOut);
                    else if (timedOut.command === "reconcile")
                        root.setFailure(timedOut.original, {
                        "code": "reconciliation_failed",
                        "message": "Couldn’t confirm what Google Calendar saved.",
                        "retryable": true
                    }, timedOut);
                    else
                        root.beginReconcile(timedOut);
                }
            } else {
                var output = mutatorOutput.text;
                if (!output.trim() && mutatorErrors.text.trim())
                    output = JSON.stringify({
                    "ok": false,
                    "error": {
                        "code": "process_error",
                        "message": mutatorErrors.text.trim(),
                        "retryable": true,
                        "details": {
                            "uncertain": finished && finished.command !== "refresh"
                        }
                    }
                });

                root.handleCommandResult(finished, code, output, mutatorErrors.text);
            }
            root.startNext();
            root.updateRefreshing();
        }

        stdout: StdioCollector {
            id: mutatorOutput
        }

        stderr: StdioCollector {
            id: mutatorErrors
        }

    }

}
