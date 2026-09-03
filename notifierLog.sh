#!/bin/sh
#
# notifierLog.sh — read the analog-notifier's activity: who registered, what was pushed, what
# was refused.
#
# The notifier logs one line per event to the journal (systemd) or to /var/log/analog-notifier.log
# (OpenRC). Raw, those lines are readable but easy to lose in announce chatter — the notifier
# re-announces every few minutes forever. This tags each line by what it is, so a session can be
# read for the two things that matter: did that phone ever register, and did a push actually go
# out for it.
#
# Snapshot by default, continuous with -f. Both read the same stream; -f is the one to leave open
# on a second terminal while testing a send from a phone.
#
# Addresses are logged as their first 8 hex characters only, so filter by that prefix — the full
# address will never match.
#
# Reads only. Needs root for the journal. No jq.
#
# Usage:
#   sudo ./notifierLog.sh                      Last 200 events, tagged
#   sudo ./notifierLog.sh -f                   Follow live (Ctrl-C to stop)
#   sudo ./notifierLog.sh -n 2000              More history
#   sudo ./notifierLog.sh --since "2 hours ago"      systemd only
#   sudo ./notifierLog.sh --only register      Registrations and rejections only
#   sudo ./notifierLog.sh --only push          APNs pushes only (mail pings and relay wakes)
#   sudo ./notifierLog.sh --only problems      Rejections, push failures, missing tokens
#   sudo ./notifierLog.sh e3680ff7             Only events about that address prefix
#   sudo ./notifierLog.sh --summary            Counts per event type instead of lines
#   sudo ./notifierLog.sh -f --only push e3680ff7    Watch one phone's pushes live
#

set -u

NOTIFIER_NAME="${NOTIFIER_NAME:-analog-notifier}"
NOTIFIER_LOG_FILE="${NOTIFIER_LOG_FILE:-/var/log/${NOTIFIER_NAME}.log}"

FOLLOW=0; LINES=200; SINCE=""; ONLY="all"; PREFIX=""; SUMMARY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--follow) FOLLOW=1 ;;
        -n) LINES="${2:-}"; [ -n "$LINES" ] || { echo "-n needs a number" >&2; exit 2; }; shift ;;
        --since) SINCE="${2:-}"; [ -n "$SINCE" ] || { echo "--since needs a value" >&2; exit 2; }; shift ;;
        --only) ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "--only needs a value" >&2; exit 2; }; shift ;;
        --summary) SUMMARY=1 ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown flag: $1 (try --help)" >&2; exit 2 ;;
        *) PREFIX="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
    esac
    shift
done

case "$ONLY" in
    all|register|push|problems|announce) ;;
    *) echo "--only takes: all, register, push, problems, announce" >&2; exit 2 ;;
esac
[ "$SUMMARY" -eq 1 ] && [ "$FOLLOW" -eq 1 ] && { echo "--summary and -f are mutually exclusive: a summary needs the stream to end." >&2; exit 2; }

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT=systemd; else INIT=openrc; fi

# The raw event stream, oldest first, one line per event. systemd carries timestamps; the OpenRC
# log is the service's stderr verbatim, so those lines have none — the tag is still applied.
log_stream() {
    if [ "$INIT" = systemd ]; then
        set -- -u "$NOTIFIER_NAME" -o short-iso --no-pager
        [ -n "$SINCE" ] && set -- "$@" --since "$SINCE"
        # --since already bounds the window; -n on top of it would silently trim the oldest half.
        [ -z "$SINCE" ] && set -- "$@" -n "$LINES"
        [ "$FOLLOW" -eq 1 ] && set -- "$@" -f
        journalctl "$@" 2>/dev/null
    else
        [ -n "$SINCE" ] && echo "[!] --since needs systemd; showing the last $LINES lines instead." >&2
        if [ ! -r "$NOTIFIER_LOG_FILE" ]; then
            echo "Cannot read $NOTIFIER_LOG_FILE (run with sudo, or set NOTIFIER_LOG_FILE)." >&2
            exit 1
        fi
        if [ "$FOLLOW" -eq 1 ]; then tail -n "$LINES" -f "$NOTIFIER_LOG_FILE"; else tail -n "$LINES" "$NOTIFIER_LOG_FILE"; fi
    fi
}

# LOG_NO_HEADER / LOG_COLOUR are for readLogs.sh, which merges this with rnsdLog.sh through a pipe:
# it prints one header of its own and decides colour from its own terminal.
[ "$FOLLOW" -eq 1 ] && [ "$SUMMARY" -eq 0 ] && [ "${LOG_NO_HEADER:-0}" != 1 ] && \
    echo "── following ${NOTIFIER_NAME} (Ctrl-C to stop) ─────────────────────────────"

log_stream | awk -v only="$ONLY" -v want="$PREFIX" -v summary="$SUMMARY" -v follow="$FOLLOW" -v force="${LOG_COLOUR:-}" '
function colour(c, s) { return tty ? "\033[" c "m" s "\033[0m" : s }
BEGIN {
    tty = (force == "1") ? 1 : (force == "0") ? 0 : (system("test -t 1") == 0)
    order = "REGISTER UNREGISTER REJECT PUSH RELAY PUSH-FAIL RELAY-FAIL COALESCE NO-TOKEN ENV-MISMATCH ANNOUNCE START OTHER"
}
{
    line = $0
    stamp = ""
    # systemd short-iso: "<ts> <host> <unit>[<pid>]: <message>". The message itself starts at the
    # notifier prefix, which is the only reliable anchor — hostnames and units contain no "[".
    if (match(line, /\[analog-notifier\] /)) {
        stamp = substr(line, 1, RSTART - 1)
        msg = substr(line, RSTART + RLENGTH)
        if (match(stamp, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+/)) stamp = substr(stamp, RSTART, RLENGTH)
        else stamp = ""
    } else {
        msg = line
    }
    if (msg == "") next

    tag = "OTHER"; group = "other"
    if (msg ~ /^registered /)                          { tag = "REGISTER";     group = "register" }
    else if (msg ~ /^unregistered /)                   { tag = "UNREGISTER";   group = "register" }
    else if (msg ~ /^\/register/)                      { tag = "REJECT";       group = "problems" }
    else if (msg ~ /^APNs ping sent for/)              { tag = "PUSH";         group = "push" }
    else if (msg ~ /^trailing ping for/)               { tag = "PUSH";         group = "push" }
    else if (msg ~ /^APNs request failed for/)         { tag = "PUSH-FAIL";    group = "problems" }
    else if (msg ~ /^APNs [0-9]+ for/)                 { tag = "PUSH-FAIL";    group = "problems" }
    else if (msg ~ /^coalesced /)                      { tag = "COALESCE";     group = "push" }
    else if (msg ~ /stored message\(s\) for unregistered/) { tag = "NO-TOKEN"; group = "problems" }
    else if (msg ~ /but that environment is not/)      { tag = "ENV-MISMATCH"; group = "problems" }
    else if (msg ~ /^relay wake: .* pushing it$/)      { tag = "RELAY";        group = "push" }
    else if (msg ~ /^relay wake: /)                    { tag = "RELAY-FAIL";   group = "problems" }
    else if (msg ~ /^announced /)                      { tag = "ANNOUNCE";     group = "announce" }
    else if (msg ~ /^registration listener up|^identity |^path-table link to rnsd|^relay wake (enabled|off)/) { tag = "START"; group = "announce" }

    # A 200 is the success line for a push, not a failure, despite sharing the "APNs <code>" shape.
    if (tag == "PUSH-FAIL" && msg ~ /^APNs 200 /) { tag = "PUSH"; group = "push" }

    if (want != "" && index(tolower(msg), want) == 0) next
    if (only != "all" && group != only) next

    count[tag]++
    total++
    if (summary == 1) next

    if (tag == "PUSH" || tag == "RELAY") painted = colour("1;32", tag)
    else if (tag == "REGISTER")   painted = colour("1;36", tag)
    else if (tag == "UNREGISTER") painted = colour("1;33", tag)
    else if (tag == "PUSH-FAIL" || tag == "RELAY-FAIL" || tag == "REJECT" || tag == "NO-TOKEN" || tag == "ENV-MISMATCH") painted = colour("1;31", tag)
    else                          painted = colour("0;90", tag)

    if (stamp != "") printf "%s  %-14s %s\n", stamp, painted, msg
    else             printf "%-14s %s\n", painted, msg
    if (follow == 1) fflush()
}
END {
    if (summary != 1) {
        if (total == 0) print "No matching events. (The notifier announces every few minutes, so an empty result usually means the filter, not a dead service.)"
        exit
    }
    if (total == 0) { print "No matching events."; exit }
    printf "%d event(s)\n\n", total
    n = split(order, tags, " ")
    for (i = 1; i <= n; i++) if (count[tags[i]] > 0) printf "  %-14s %d\n", tags[i], count[tags[i]]
}
'
