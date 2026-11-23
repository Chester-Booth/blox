.pragma library

// Pure human-readable headings and detail copy for calendar adapter failures.
function failureHeading(item, errorObject) {
    const command = item.command;
    const code = errorObject && errorObject.code || "provider_error";
    const byCode = {
        partial_mutation: "Google Calendar only completed part of the change",
        not_applied: "Google Calendar did not save the change",
        reconciliation_failed: "Couldn’t confirm what Google Calendar saved",
        auth_required: "Google Calendar needs you to sign in",
        etag_conflict: "This event changed in Google Calendar",
        permission_denied: "Google Calendar refused this change",
        rate_limited: "Google Calendar is busy",
        provider_unavailable: "Google Calendar is unavailable"
    };
    if (byCode[code])
        return byCode[code];
    if (code === "timeout")
        return command === "refresh" ? "Calendar refresh timed out" : "The calendar request timed out";
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
    const command = item.command;
    const code = errorObject && errorObject.code || "provider_error";
    const byCode = {
        partial_mutation: "Refresh to see the result before trying another change.",
        not_applied: "The event is unchanged. You can try again.",
        reconciliation_failed: "It will retry when the connection returns. You can also retry now.",
        auth_required: "Run gcalcli once, then return and try again.",
        etag_conflict: "Reload the latest version before saving your changes.",
        permission_denied: "Check that this calendar still allows changes.",
        rate_limited: "Wait a moment, then try again."
    };
    if (byCode[code])
        return byCode[code];
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
