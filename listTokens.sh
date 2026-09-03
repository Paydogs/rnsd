#!/bin/sh
#
# listTokens.sh — show the APNs registrations the notifier holds.
#
# One row per registered LXMF address: which push environment it is bound to, which app bundle
# registered it, and how long ago. This is the answer to "does the server know how to wake that
# phone" — a device missing here can only ever be reached while it happens to be awake, because
# nothing can push it.
#
# Device tokens are credentials, so only the last 8 characters are printed. --full overrides that
# for the case where you need to match one against Apple's feedback, and says so.
#
# Reads only. Needs root (the token DB is 0640, owned by the reticulum user) and python3, which
# the notifier already depends on. No jq.
#
# Usage:
#   sudo ./listTokens.sh                 Every registration, newest first
#   sudo ./listTokens.sh e3680ff7        Only addresses starting with that prefix
#   sudo ./listTokens.sh --env sandbox   Only one push environment
#   sudo ./listTokens.sh --full          Print whole tokens (credentials — avoid pasting these)
#   sudo ./listTokens.sh --json          The raw DB, unmodified
#

set -u

NOTIFIER_CONF_DIR="${NOTIFIER_CONF_DIR:-/etc/analog}"
NOTIFIER_CONF="${NOTIFIER_CONF:-${NOTIFIER_CONF_DIR}/notifier.conf}"
NOTIFIER_STATE_DIR="${NOTIFIER_STATE_DIR:-/var/lib/analog-notifier}"

PREFIX=""; ENV_FILTER=""; FULL=0; RAW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --full) FULL=1 ;;
        --json) RAW=1 ;;
        --env) ENV_FILTER="${2:-}"; [ -n "$ENV_FILTER" ] || { echo "--env needs a value" >&2; exit 2; }; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown flag: $1 (try --help)" >&2; exit 2 ;;
        *) PREFIX="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo $0) — the token DB is not world-readable." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found — it ships with the notifier; is this the right host?" >&2; exit 1; }

# conf_get SECTION KEY (ini, keys at column 0) — same reader as checkHealth.sh.
conf_get() {
    awk -v sec="[$1]" -v key="$2" '
        /^\[/ { insec = ($0 == sec) }
        insec && $1 == key && $2 == "=" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*[#;].*$/, ""); print; exit }
    ' "${NOTIFIER_CONF}" 2>/dev/null
}

TOKEN_DB="$(conf_get notifier token_db)"
[ -n "${TOKEN_DB}" ] || TOKEN_DB="${NOTIFIER_STATE_DIR}/tokens.json"

if [ ! -f "${TOKEN_DB}" ]; then
    echo "No token DB at ${TOKEN_DB}."
    echo "Nothing has ever registered, or notifier.conf points elsewhere (token_db in ${NOTIFIER_CONF})."
    exit 1
fi

if [ "$RAW" -eq 1 ]; then
    cat "${TOKEN_DB}"
    exit 0
fi

TOKEN_DB="${TOKEN_DB}" PREFIX="${PREFIX}" ENV_FILTER="${ENV_FILTER}" FULL="${FULL}" python3 - <<'PYEOF'
import json, os, sys, time

path = os.environ["TOKEN_DB"]
prefix = os.environ["PREFIX"]
env_filter = os.environ["ENV_FILTER"]
full = os.environ["FULL"] == "1"

try:
    with open(path) as handle:
        raw = json.load(handle)
except Exception as exc:
    print(f"token DB unreadable ({path}): {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(raw, dict):
    print(f"token DB is not an object ({path}) — refusing to guess at its shape", file=sys.stderr)
    sys.exit(1)

def age(seconds):
    if not seconds:
        return "?"
    delta = int(time.time()) - int(seconds)
    if delta < 0:
        return "in the future"
    days, rem = divmod(delta, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h ago"
    if hours:
        return f"{hours}h {minutes}m ago"
    return f"{minutes}m ago"

rows = []
for address, value in raw.items():
    # Registrations written before the env/bundle fields existed are a bare token string, and
    # the notifier still reads those as production — so they are shown, not skipped.
    if isinstance(value, str):
        token, env, bundle, updated, legacy = value, "production", "", 0, True
    elif isinstance(value, dict):
        token = str(value.get("token", ""))
        env = str(value.get("env", "?"))
        bundle = str(value.get("bundle_id", ""))
        updated = value.get("updated", 0)
        legacy = False
    else:
        continue
    if prefix and not address.lower().startswith(prefix):
        continue
    if env_filter and env != env_filter:
        continue
    rows.append((updated or 0, address, env, bundle, token, legacy))

rows.sort(reverse=True)

total = len(raw)
if not rows:
    what = []
    if prefix:
        what.append(f"prefix '{prefix}'")
    if env_filter:
        what.append(f"env '{env_filter}'")
    print(f"No registration matching {' and '.join(what)}." if what else "No registrations.")
    print(f"({total} registration(s) in the DB — that address has never registered, or registered under another identity.)")
    sys.exit(0)

shown = f"{len(rows)} of {total}" if len(rows) != total else str(total)
print(f"{shown} registration(s) in {path}")
print()
print(f"{'LXMF ADDRESS':<34} {'ENV':<11} {'BUNDLE':<16} {'TOKEN':<{64 if full else 12}} UPDATED")
for updated, address, env, bundle, token, legacy in rows:
    shown_token = token if full else ("…" + token[-8:] if len(token) > 8 else token)
    note = "  (pre-env record, treated as production)" if legacy else ""
    print(f"{address:<34} {env:<11} {bundle or '-':<16} {shown_token:<{64 if full else 12}} {age(updated)}{note}")

if full:
    print()
    print("Those are live device tokens. Don't paste them anywhere you wouldn't paste a password.")
PYEOF
