#!/bin/sh
#
# readLogs.sh — the notifier's log and rnsd's log in one stream, in time order.
#
# A message's journey through this server crosses two daemons: rnsd sees the phone connect and the
# packets move, the notifier sees the stored mail and sends the push. Read separately the two halves
# never line up; this merges notifierLog.sh and rnsdLog.sh (same tagging, same filters) and marks
# every line with where it came from, so a send from a phone can be followed from "Client connected"
# to "APNs ping sent" without switching terminals.
#
# Snapshot by default, ordered by timestamp across both sources; continuous with -f, where lines
# print as each daemon emits them. --summary prints each source's counts one after the other.
#
# Lines without a timestamp (OpenRC logs, Python tracebacks) sort with the last stamped line before
# them, so a traceback stays under the error that produced it.
#
# Reads only. Needs root for the journal. No jq. Expects notifierLog.sh and rnsdLog.sh beside it.
#
# Usage:
#   sudo ./readLogs.sh                        Last 200 events from each, merged
#   sudo ./readLogs.sh -f                     Follow both live (Ctrl-C to stop)
#   sudo ./readLogs.sh -n 2000                More history from each
#   sudo ./readLogs.sh --since "2 hours ago"  systemd only
#   sudo ./readLogs.sh --only problems        Errors, warnings, refusals and failed pushes from both
#   sudo ./readLogs.sh e3680ff7               Only lines mentioning that text, from both
#   sudo ./readLogs.sh --summary              Counts per event type, per source
#   sudo ./readLogs.sh -f e3680ff7            Follow one phone through both daemons
#
# For a source-specific filter (--only interfaces, --only register, …) use the individual script.
#

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
NOTIFIER_SCRIPT="${HERE}/notifierLog.sh"
RNSD_SCRIPT="${HERE}/rnsdLog.sh"
for s in "$NOTIFIER_SCRIPT" "$RNSD_SCRIPT"; do
    [ -f "$s" ] || { echo "Missing $s — readLogs.sh needs notifierLog.sh and rnsdLog.sh beside it." >&2; exit 1; }
done

FOLLOW=0; LINES=200; SINCE=""; ONLY="all"; MATCH=""; SUMMARY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--follow) FOLLOW=1 ;;
        -n) LINES="${2:-}"; [ -n "$LINES" ] || { echo "-n needs a number" >&2; exit 2; }; shift ;;
        --since) SINCE="${2:-}"; [ -n "$SINCE" ] || { echo "--since needs a value" >&2; exit 2; }; shift ;;
        --only) ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "--only needs a value" >&2; exit 2; }; shift ;;
        --summary) SUMMARY=1 ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown flag: $1 (try --help)" >&2; exit 2 ;;
        *) MATCH="$1" ;;
    esac
    shift
done

case "$ONLY" in
    all|problems) ;;
    *) echo "--only takes: all, problems (the two groups both sources share; use notifierLog.sh / rnsdLog.sh for the rest)" >&2; exit 2 ;;
esac
[ "$SUMMARY" -eq 1 ] && [ "$FOLLOW" -eq 1 ] && { echo "--summary and -f are mutually exclusive: a summary needs the stream to end." >&2; exit 2; }

# The children decide colour from their own stdout, which here is a pipe; tell them what ours is.
if [ -t 1 ]; then LOG_COLOUR=1; else LOG_COLOUR=0; fi
export LOG_COLOUR
export LOG_NO_HEADER=1

# Arguments passed through to both children, minus -f (handled here).
set -- -n "$LINES"
[ -n "$SINCE" ] && set -- "$@" --since "$SINCE"
[ "$ONLY" != all ] && set -- "$@" --only "$ONLY"
[ "$SUMMARY" -eq 1 ] && set -- "$@" --summary
[ -n "$MATCH" ] && set -- "$@" "$MATCH"

# Prefix each child's line with its source, right after the timestamp when there is one. Both
# children put the stamp first: rnsdLog as "YYYY-MM-DD HH:MM:SS", notifierLog as the journal's
# ISO form "YYYY-MM-DDTHH:MM:SS+ZZZZ". The stamp is normalised to the first form so the columns
# line up across sources (both are local time). Colour codes never precede the stamp.
label() {
    awk -v src="$1" -v tty="$LOG_COLOUR" '
    function paint(s) { return tty == "1" ? "\033[1;35m" s "\033[0m" : s }
    {
        if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}[0-9:+-]*  */)) {
            stamp = substr($0, 1, 19); sub(/T/, " ", stamp)
            printf "%s  %s  %s\n", stamp, paint(sprintf("%-8s", src)), substr($0, RLENGTH + 1)
        } else {
            printf "%-19s  %s  %s\n", "", paint(sprintf("%-8s", src)), $0
        }
        fflush()
    }'
}

if [ "$SUMMARY" -eq 1 ]; then
    echo "── ${NOTIFIER_SCRIPT##*/} ──────────────────────────────────────────────────"
    sh "$NOTIFIER_SCRIPT" "$@"
    echo
    echo "── ${RNSD_SCRIPT##*/} ──────────────────────────────────────────────────────"
    sh "$RNSD_SCRIPT" "$@"
    exit 0
fi

if [ "$FOLLOW" -eq 1 ]; then
    echo "── following analog-notifier + rnsd (Ctrl-C to stop) ───────────────────────"
    # Two followers writing line-by-line into the same stdout; each awk flushes per line, so lines
    # interleave whole. The trap makes Ctrl-C take both children down with us.
    trap 'kill 0 2>/dev/null' INT TERM EXIT
    sh "$NOTIFIER_SCRIPT" -f "$@" | label NOTIFIER &
    sh "$RNSD_SCRIPT" -f "$@" | label RNSD &
    wait
    exit 0
fi

# Snapshot: merge in time order. The sort key is the stamp normalised to "YYYY-MM-DD HH:MM:SS";
# a line without one inherits the previous line's key so it stays where it was emitted. The key
# is prefixed with a tab and stripped after sorting; `sort -s` keeps emission order within a second.
{
    sh "$NOTIFIER_SCRIPT" "$@" | label NOTIFIER
    sh "$RNSD_SCRIPT" "$@" | label RNSD
} | awk '
{
    if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        key = substr($0, 1, 19); sub(/T/, " ", key)
    } else if (key == "") {
        key = "0000-00-00 00:00:00"
    }
    printf "%s\t%s\n", key, $0
}' | sort -s -t "$(printf '\t')" -k1,1 | cut -f2-
