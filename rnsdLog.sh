#!/bin/sh
#
# rnsdLog.sh — read the Reticulum transport daemon's log: interfaces coming and going, errors,
# and (at a raised loglevel) announces, paths and links.
#
# rnsd logs one line per event as "[<date time>] [<Level>] <message>", to the journal (systemd) or
# to /var/log/rnsd.log (OpenRC). Levels are Reticulum's own: Critical, Error, Warning, Notice,
# Info, Verbose, Debug, Extreme. This keeps the level as the tag, adds a topic column (what the
# line is about), and lets a session be read for the two things that matter on this node: did an
# interface drop or reconnect, and did anything go wrong.
#
# Snapshot by default, continuous with -f. Both read the same stream; -f is the one to leave open
# on a second terminal while testing from a phone.
#
# The default rnsd loglevel (4, Info) records interface events and problems only. Announces,
# path decisions and link setup appear from loglevel 5 (Verbose); set `loglevel` under [logging]
# in /var/lib/reticulum/.reticulum/config and restart rnsd. `--only announces` on a level-4 node
# is therefore empty by design, not broken.
#
# Reads only. Needs root for the journal. No jq.
#
# Usage:
#   sudo ./rnsdLog.sh                        Last 200 events, tagged
#   sudo ./rnsdLog.sh -f                     Follow live (Ctrl-C to stop)
#   sudo ./rnsdLog.sh -n 2000                More history
#   sudo ./rnsdLog.sh --since "2 hours ago"  systemd only
#   sudo ./rnsdLog.sh --only problems        Critical, Error and Warning lines only
#   sudo ./rnsdLog.sh --only interfaces      Interface connects, drops, reconnects, spawns
#   sudo ./rnsdLog.sh --only announces       Announce handling (needs loglevel >= 5)
#   sudo ./rnsdLog.sh --only paths           Path table decisions and path requests (loglevel >= 5)
#   sudo ./rnsdLog.sh --only links           Link establishment and teardown (loglevel >= 5)
#   sudo ./rnsdLog.sh e3680ff7               Only lines mentioning that text (address prefix, interface name, IP)
#   sudo ./rnsdLog.sh --summary              Counts per level and per topic instead of lines
#   sudo ./rnsdLog.sh -f --only interfaces 4242    Watch the TCP server's clients live
#

set -u

RNSD_NAME="${RNSD_NAME:-rnsd}"
RNSD_LOG_FILE="${RNSD_LOG_FILE:-/var/log/${RNSD_NAME}.log}"

FOLLOW=0; LINES=200; SINCE=""; ONLY="all"; MATCH=""; SUMMARY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--follow) FOLLOW=1 ;;
        -n) LINES="${2:-}"; [ -n "$LINES" ] || { echo "-n needs a number" >&2; exit 2; }; shift ;;
        --since) SINCE="${2:-}"; [ -n "$SINCE" ] || { echo "--since needs a value" >&2; exit 2; }; shift ;;
        --only) ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "--only needs a value" >&2; exit 2; }; shift ;;
        --summary) SUMMARY=1 ;;
        -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown flag: $1 (try --help)" >&2; exit 2 ;;
        *) MATCH="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
    esac
    shift
done

case "$ONLY" in
    all|problems|interfaces|announces|paths|links) ;;
    *) echo "--only takes: all, problems, interfaces, announces, paths, links" >&2; exit 2 ;;
esac
[ "$SUMMARY" -eq 1 ] && [ "$FOLLOW" -eq 1 ] && { echo "--summary and -f are mutually exclusive: a summary needs the stream to end." >&2; exit 2; }

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT=systemd; else INIT=openrc; fi

# The raw stream, oldest first. rnsd stamps its own lines, so the journal's timestamp is only a
# fallback for lines that bypassed RNS.log (Python tracebacks, service manager notes).
log_stream() {
    if [ "$INIT" = systemd ]; then
        set -- -u "$RNSD_NAME" -o short-iso --no-pager
        [ -n "$SINCE" ] && set -- "$@" --since "$SINCE"
        # --since already bounds the window; -n on top of it would silently trim the oldest half.
        [ -z "$SINCE" ] && set -- "$@" -n "$LINES"
        [ "$FOLLOW" -eq 1 ] && set -- "$@" -f
        journalctl "$@" 2>/dev/null
    else
        [ -n "$SINCE" ] && echo "[!] --since needs systemd; showing the last $LINES lines instead." >&2
        if [ ! -r "$RNSD_LOG_FILE" ]; then
            echo "Cannot read $RNSD_LOG_FILE (run with sudo, or set RNSD_LOG_FILE)." >&2
            exit 1
        fi
        if [ "$FOLLOW" -eq 1 ]; then tail -n "$LINES" -f "$RNSD_LOG_FILE"; else tail -n "$LINES" "$RNSD_LOG_FILE"; fi
    fi
}

# LOG_NO_HEADER / LOG_COLOUR are for readLogs.sh, which merges this with notifierLog.sh through a
# pipe: it prints one header of its own and decides colour from its own terminal.
[ "$FOLLOW" -eq 1 ] && [ "$SUMMARY" -eq 0 ] && [ "${LOG_NO_HEADER:-0}" != 1 ] && \
    echo "── following ${RNSD_NAME} (Ctrl-C to stop) ─────────────────────────────────"

log_stream | awk -v only="$ONLY" -v want="$MATCH" -v summary="$SUMMARY" -v follow="$FOLLOW" -v force="${LOG_COLOUR:-}" '
function colour(c, s) { return tty ? "\033[" c "m" s "\033[0m" : s }
BEGIN {
    tty = (force == "1") ? 1 : (force == "0") ? 0 : (system("test -t 1") == 0)
    levels = "Critical Error Warning Notice Info Verbose Debug Extreme Other"
    topics = "interfaces announces paths links transport other"
}
{
    line = $0
    stamp = ""; level = "Other"; msg = line
    # RNS.log lines: "[YYYY-MM-DD HH:MM:SS] [Level]   message". The level token is the anchor;
    # the journal prefix (iso time, host, unit[pid]:) sits before it and is dropped.
    if (match(line, /\[(Critical|Error|Warning|Notice|Info|Verbose|Debug|Extreme)\] */)) {
        level = substr(line, RSTART + 1, RLENGTH - 1); sub(/\] *$/, "", level)
        msg = substr(line, RSTART + RLENGTH)
        head = substr(line, 1, RSTART - 1)
        if (match(head, /\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\]/)) stamp = substr(head, RSTART + 1, RLENGTH - 2)
        else if (match(head, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+/)) stamp = substr(head, RSTART, RLENGTH)
    } else {
        # Not an RNS.log line: a traceback, or the service manager. Keep the journal stamp if any.
        if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ /)) { stamp = substr(line, 1, RLENGTH - 1); msg = substr(line, RLENGTH + 1) }
        sub(/^[^ ]+ [^ ]+\[[0-9]+\]: /, "", msg)
    }
    if (msg == "") next

    # Topic by content. The verbose-level chatter (announces, paths, links) is classified first
    # because those lines name the interface they arrived on and would otherwise all fold into
    # "interfaces"; then the interface lifecycle itself; the rest of the transport is one bucket.
    lm = tolower(msg)
    if (lm ~ /announce/) topic = "announces"
    else if (lm ~ /path/) topic = "paths"
    else if (lm ~ /link/) topic = "links"
    else if (lm ~ /interface|socket|spawn|client connected|client disconnected|connection established|carrier|reconnect|listener/) topic = "interfaces"
    else if (lm ~ /transport|packet|hashlist|tunnel|destination/) topic = "transport"
    else topic = "other"

    if (want != "" && index(lm, want) == 0) next
    if (only == "problems") { if (level != "Critical" && level != "Error" && level != "Warning") next }
    else if (only != "all" && topic != only) next

    lcount[level]++; tcount[topic]++
    total++
    if (summary == 1) next

    if (level == "Critical" || level == "Error") painted = colour("1;31", level)
    else if (level == "Warning")                 painted = colour("1;33", level)
    else if (level == "Notice")                  painted = colour("1;36", level)
    else if (level == "Info")                    painted = colour("1;32", level)
    else                                         painted = colour("0;90", level)

    if (stamp != "") printf "%s  %-8s %-10s %s\n", stamp, painted, topic, msg
    else             printf "%-8s %-10s %s\n", painted, topic, msg
    if (follow == 1) fflush()
}
END {
    if (summary != 1) {
        if (total == 0) print "No matching lines. (At the default loglevel rnsd is quiet between interface events; announces/paths/links need loglevel >= 5 — see --help.)"
        exit
    }
    if (total == 0) { print "No matching lines."; exit }
    printf "%d line(s)\n\nby level\n", total
    n = split(levels, l, " ")
    for (i = 1; i <= n; i++) if (lcount[l[i]] > 0) printf "  %-10s %d\n", l[i], lcount[l[i]]
    printf "\nby topic\n"
    n = split(topics, t, " ")
    for (i = 1; i <= n; i++) if (tcount[t[i]] > 0) printf "  %-10s %d\n", t[i], tcount[t[i]]
}
'
