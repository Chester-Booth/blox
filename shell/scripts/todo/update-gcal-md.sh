#!/bin/bash

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$HOME/.cache/gcal_script"
DAY_OUT="$HOME/Documents/todo/2-gcal.md"
WEEK_OUT="$HOME/Documents/todo/99-gcal_week.md"
NOW_HOUR=$(date +%H)
NOW_DATE=$(date +"%a %b %d") # e.g., "Mon Mar 09"
auth_notification_sent=0

# Create cache dir if it doesn't exist
mkdir -p "$CACHE_DIR"

notify_auth_expired() {
	if [ "$auth_notification_sent" -eq 1 ]; then
		return
	fi
	auth_notification_sent=1

	if command -v systemd-run >/dev/null 2>&1; then
		systemd-run --user --quiet --collect \
			--unit=gcalcli-auth-notify \
			"$SCRIPT_DIR/gcalcli-auth-notify.sh" >/dev/null 2>&1 && return
	fi

	"$SCRIPT_DIR/gcalcli-auth-notify.sh" >/dev/null 2>&1 &
}

# --- PROCESSING FUNCTION ---
process_gcal() {
	# $1 = "offline", "expired", "online", or "error"
	# $2 = error message (if "error")
	local status=$1
	local err_msg=$2

	# We pipe input into this block
	# 1. Update regex to [0-9;]*35m to capture both Normal (0;35m) and Bold (1;35m)
	# 2. Note: Current events become Red (31m) and lose their Purple tag. We handle this in awk.
	# 3. Remove all angle brackets (< and >) as they break the output
	sed -E \
		-e 's/<br\/?>//g' \
		-e 's/[<>]//g' \
		-e 's/\x1b\[[0-9;]*35m/▒/g' \
		-e 's/\x1b\[[0-9;]*36m/▕/g' \
		-e 's/\x1b\[[0-9;]*m//g' \
		-e 's/(▒|▕)/\n\1/g' |
		awk -v nowh="$NOW_HOUR" -v nowd="$NOW_DATE" -v stat="$status" -v err="$err_msg" '
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
    function print_buffer() { if (buffer != "") { print buffer; buffer = "" } }

    BEGIN { 
        uni_modified = 0 
        is_today = 0
        
        # Normalize spaces in the current date just in case of single digit days (e.g. Mar  9 vs Mar 9)
        norm_nowd = nowd
        gsub(/  +/, " ", norm_nowd)

        if (stat == "offline") {
            print "󰖪 "
        } else if (stat == "expired") {
            print "󱦃 "
        } else if (stat == "error") {
            print " " err
        }
    }

    {
        line = ltrim($0)
        if (line == "") next

        # 1. DATE LINE
        if (line ~ /^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]+/) {
            print_buffer()
            
            # Check if this date block is "today"
            norm_line = line
            gsub(/  +/, " ", norm_line)
            if (index(norm_line, norm_nowd) == 1) {
                is_today = 1
            } else {
                is_today = 0
            }

            if (match(line, / [0-9]*:[0-9]{2}/)) {
                print substr(line, 1, RSTART-1)
                line = substr(line, RSTART)
                line = ltrim(line)
            } else {
                print line
                next
            }
        }

        # 2. EVENT LINE
        sym = substr(line, 1, 1)
        if (sym != "▒" && sym != "▕") {
            if (line ~ /^[0-9:]/) sym = "▕"
            else {} 
        } else {
            line = substr(line, 2)
        }

        if (match(line, /([0-9]*):([0-9]{2})[ \t]*-[ \t]*([0-9]*):([0-9]{2})/, t)) {
            print_buffer()
            uni_modified = 0
            sh = t[1] + 0; sm = t[2]; eh = t[3] + 0; em = t[4]
            rest = substr(line, RSTART + RLENGTH)
            rest = ltrim(rest)
            rest = rtrim(rest)

            # --- FIX LOGIC ---
            # Identify Uni event if:
            # 1. Symbol is ▒ (Purple)
            # 2. OR Text starts with "CODE - " (Handles Red/Current events where color is lost)
            is_uni = (sym == "▒")
            if (!is_uni && rest ~ /^[A-Z0-9]+ - /) {
                is_uni = 1
            }

            if (is_uni) {
                idx = index(rest, " - ")
                if (idx > 0) { rest = substr(rest, idx + 3); uni_modified = 1 }
            }
            # -----------------

            # Overwrite symbol with arrow ONLY if it is today AND current hour
            if (is_today && nowh >= sh && nowh < eh) sym = "➡️"

            buffer = sprintf("%s  %02d:%s-%02d:%s   %s", sym, sh, sm, eh, em, rest)
            next
        }

        # 3. LOCATION LINE
        if (index(line, "Location:") == 1) {
            loc = substr(line, 10)
            loc = ltrim(rtrim(loc))
            if (uni_modified) {
                if (match(loc, /\(([^)]+)\)/, m)) loc = m[1]
            }
            if (buffer != "" && loc != "") buffer = buffer "  " loc
            next
        }
    }
    END { print_buffer() }
    '
}

# --- FETCH AND GENERATE ---

generate_file() {
	local cmd_args="$1"
	local cache_file="$2"
	local out_file="$3"
	local temp_raw
	local temp_err
	local args
	read -r -a args <<<"$cmd_args"

	# Capture stderr to detect token expiration errors
	temp_err=$(mktemp)
	if temp_raw=$(timeout 25s gcalcli agenda --military --details=end --details=location --width=300 "${args[@]}" 2>"$temp_err"); then
		if [ -n "$temp_raw" ]; then
			echo "$temp_raw" >"$cache_file"
			echo "$temp_raw" | process_gcal "online" "" >"$out_file"
			rm -f "$temp_err"
			return
		fi
	fi

	# Check if the error was a token expiration/revocation, a Wi-Fi error, or something else
	local status="offline"
	local ext_err=""
	if [ -f "$temp_err" ] && [ -s "$temp_err" ]; then
		if grep -q "invalid_grant.*Token has been expired or revoked" "$temp_err"; then
			# 1. Auth/Expired Token Error (explicitly handled)
			status="expired"
			notify_auth_expired
		elif grep -qEi "ServerNotFoundError|gaierror|Network is unreachable|Name or service not known|Connection refused|Timeout|ConnectionError|Failed to establish a new connection|NewConnectionError|nodename nor servname provided" "$temp_err"; then
			# 2. Wi-Fi/No Internet Error (explicitly handled)
			status="offline"
		else
			# 3. Arbitrary/New Error - Extracted from the last non-empty line of the stack trace
			status="error"
			ext_err=$(awk 'NF' "$temp_err" | tail -n 1)
			# If the output somehow didn't have any non-empty lines, silently fallback to offline
			if [ -z "$ext_err" ]; then
				status="offline"
			fi
		fi
	fi
	rm -f "$temp_err"

	if [ -f "$cache_file" ]; then
		cat "$cache_file" | process_gcal "$status" "$ext_err" >"$out_file"
	else
		if [ "$status" = "expired" ]; then
			echo "󱦃 No Data" >"$out_file"
		elif [ "$status" = "error" ]; then
			echo " $ext_err" >"$out_file"
		else
			echo "󰖪 No Data" >"$out_file"
		fi
	fi
}

# 1. Daily Agenda
generate_file "today tomorrow" "$CACHE_DIR/day.cache" "$DAY_OUT"

# 2. Weekly Agenda
# Mon-Fri: show current week (today->sunday)
# Sat-Sun: show next week (today->next sunday)
DAY_OF_WEEK=$(date +%u) # 1=Monday, 7=Sunday
if [ "$DAY_OF_WEEK" -ge 6 ]; then
	# Weekend: show through next Sunday
	# Calculate next Sunday's date (7 days from now if Sunday, 8 days if Saturday)
	if [ "$DAY_OF_WEEK" -eq 7 ]; then
		# Today is Sunday, next Sunday is +7 days
		NEXT_SUNDAY=$(date -d "+7 days" +%Y-%m-%d)
	else
		# Today is Saturday, next Sunday is +8 days
		NEXT_SUNDAY=$(date -d "+8 days" +%Y-%m-%d)
	fi
	generate_file "today $NEXT_SUNDAY" "$CACHE_DIR/week.cache" "$WEEK_OUT"
else
	# Weekday: show through this Sunday
	generate_file "today sunday" "$CACHE_DIR/week.cache" "$WEEK_OUT"
fi
