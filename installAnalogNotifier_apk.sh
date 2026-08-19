#!/bin/sh
#
# install-analog-notifier.sh  (Alpine / OpenRC variant)
#
# Companion to installRnsd_apk.sh. Sets up the two server-side pieces the
# iOS background wake-up design needs alongside a running rnsd:
#
#   1. lxmd  — the LXMF Propagation Node daemon (store-and-forward). Holds
#              offline messages until the recipient's app acks. Runs against
#              the shared rnsd instance (--rnsconfig).
#
#   2. analog-notifier — the distributed APNs wake-up service. Two modes:
#        a) --register  (daemon): announces a registration Destination on the
#           shared RNS instance, receives {lxmf_hash, apns_token} bindings that
#           apps send at pairing over RNS, writes the token DB.
#        b) --trigger   (on_inbound hook): lxmd runs this when a message is
#           received; it coalesces (one ping per hash per window), looks up the
#           token, and sends an APNs push with mutable-content=1.
#
# Design invariants (see Analog: Documentation/Future/iOS-APNs-Wake-Up-Ping.html):
#   - The notifier NEVER has message plaintext. Only the recipient hash (to
#     look up the token) and, in the full design, an E2E ciphertext envelope.
#   - A missed ping is a delayed message, never a lost one: lxmd holds mail
#     until ack. This service only buys latency back.
#
# Status: SKELETON. Ops scaffolding is real; on_inbound contract, encrypted-
# envelope/NSE payload, and registration auth are TODO (see analog_notifier.py).
#
# Usage:  sudo ./install-analog-notifier.sh
# Requires: rnsd already installed by installRnsd_apk.sh.
#

set -eu

# ---------- Configurable knobs ----------------------------------------------
RNS_USER="${RNS_USER:-reticulum}"
RNS_GROUP="${RNS_GROUP:-reticulum}"
RNS_HOME="${RNS_HOME:-/var/lib/reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-${RNS_HOME}/.reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-${RNS_HOME}/.lxmd}"

NOTIFIER_NAME="analog-notifier"
NOTIFIER_INSTALL_DIR="${NOTIFIER_INSTALL_DIR:-/opt/analog-notifier}"
NOTIFIER_CONF_DIR="${NOTIFIER_CONF_DIR:-/etc/analog}"
NOTIFIER_STATE_DIR="${NOTIFIER_STATE_DIR:-/var/lib/analog-notifier}"
NOTIFIER_LOG_DIR="${NOTIFIER_LOG_DIR:-/var/log/analog-notifier}"
# ----------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

# All work in main(); only invoked on the final line so a truncated download
# (wget | sh) can't execute a partial function body.
main() {

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (try: sudo $0)"
    exit 1
fi

# Alpine + OpenRC
if [ ! -f /etc/alpine-release ]; then
    warn "This does not look like Alpine Linux. Continuing anyway..."
fi
if ! command -v rc-update >/dev/null 2>&1; then
    err "OpenRC (rc-update) not found. Use installAnalogNotifier_apt.sh on systemd."
    exit 1
fi

# Depends on rnsd being installed.
if [ ! -d "${RNS_CONFIG_DIR}" ]; then
    err "Reticulum config dir ${RNS_CONFIG_DIR} not found."
    err "Run installRnsd_apk.sh first — this installer shares the rnsd user and RNS instance."
    exit 1
fi
if ! id -u "${RNS_USER}" >/dev/null 2>&1; then
    err "Service user '${RNS_USER}' not found. Run installRnsd_apk.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. System + Python dependencies
# ---------------------------------------------------------------------------
log "Updating apk index and installing system dependencies..."
apk update || warn "apk update reported errors (stale mirror?) — continuing"
apk add --no-cache python3 py3-pip

log "Ensuring lxmf (provides lxmd) is installed..."
pip3 install --upgrade --break-system-packages lxmf

LXMD_BIN="$(command -v lxmd || true)"
if [ -z "${LXMD_BIN}" ]; then
    err "lxmd binary not found after installing lxmf."
    exit 1
fi
log "lxmd installed at ${LXMD_BIN}"

log "Installing notifier Python deps (PyJWT, httpx[http2])..."
# py3-cryptography is already present (rns dep); PyJWT + httpx come via pip.
pip3 install --upgrade --break-system-packages "PyJWT" "httpx[http2]"

# ---------------------------------------------------------------------------
# 2. Directory layout
# ---------------------------------------------------------------------------
log "Creating notifier directories..."
mkdir -p "${NOTIFIER_INSTALL_DIR}" \
         "${NOTIFIER_CONF_DIR}" \
         "${NOTIFIER_STATE_DIR}" \
         "${NOTIFIER_LOG_DIR}" \
         "${LXMD_CONFIG_DIR}"

chown -R "root:${RNS_GROUP}" "${NOTIFIER_INSTALL_DIR}" "${NOTIFIER_CONF_DIR}"
chmod 755 "${NOTIFIER_INSTALL_DIR}"
chmod 750 "${NOTIFIER_CONF_DIR}"

chown -R "${RNS_USER}:${RNS_GROUP}" "${NOTIFIER_STATE_DIR}" "${NOTIFIER_LOG_DIR}" "${LXMD_CONFIG_DIR}"
chmod 750 "${NOTIFIER_STATE_DIR}" "${NOTIFIER_LOG_DIR}" "${LXMD_CONFIG_DIR}"

# ---------------------------------------------------------------------------
# 3. analog_notifier.py  (register daemon + on_inbound trigger)
# ---------------------------------------------------------------------------
log "Writing ${NOTIFIER_INSTALL_DIR}/analog_notifier.py"
cat > "${NOTIFIER_INSTALL_DIR}/analog_notifier.py" <<'PYEOF'
#!/usr/bin/env python3
"""Analog APNs Notifier — skeleton.

Two modes:
  --register            Long-running daemon. Announces a registration
                        Destination on the shared RNS instance, receives
                        {lxmf_hash, apns_token} bindings that apps send at
                        pairing over RNS, writes the token DB. Run as a service.

  --trigger             Invoked by lxmd's --on-inbound hook when a message is
    [--recipient-hash H] received. Coalesces (one ping per hash per window),
    [--from-stdin]       looks up the token, sends an APNs push with
                        mutable-content=1. Stateless except for the
                        coalesce-state file (flock-guarded).

DESIGN INVARIANTS (see Documentation/Future/iOS-APNs-Wake-Up-Ping.html):
  - The notifier NEVER has message plaintext. It learns only the recipient
    destination hash (to look up the token) and, in the full design, a small
    E2E-encrypted envelope (ciphertext) to carry in the push payload.
    Ciphertext is not content.
  - A missed ping is a delayed message, never a lost one: lxmd store-and-
    forward holds the message until the app acks. This only buys latency.

TODO (skeleton — must verify/complete before production):
  - Encrypted-envelope extraction from the inbound LXMF message + the NSE
    payload (memo section 05). Today this sends a content-free wake ping.
  - Registration-packet authentication (memo section 08): over RNS the
    registration packet must be signed by the registering identity. Enforce.
  - lxmd on_inbound contract: confirm exactly what lxmd passes (stdin bytes?
    file path? args?) and parse the recipient hash robustly. Currently
    --recipient-hash is authoritative; --from-stdin parse is a stub.
  - lxmd on_inbound fires for messages accepted into the propagation store
    (not only locally-delivered). If not, a polling fallback over lxmd's
    message store directory is the alternative.
"""
import argparse
import configparser
import fcntl
import json
import os
import sys
import time
from pathlib import Path

DEFAULT_CONF = "/etc/analog/notifier.conf"

log = lambda *a: print("[analog-notifier]", *a, file=sys.stderr, flush=True)


def load_config(path):
    cp = configparser.ConfigParser()
    if not Path(path).exists():
        log(f"config {path} not found — notifier dormant")
        return None
    cp.read(path)
    return cp


def configured(cp):
    """True only if the operator has supplied real APNs credentials."""
    if cp is None:
        return False
    a = cp["apns"]
    return all(
        a.get(k, "").strip() not in ("", "REPLACE_ME")
        for k in ("team_id", "key_id", "bundle_id", "key_path")
    ) and Path(a["key_path"]).exists()


# --- token DB: {lxmf_destination_hash_hex: apns_device_token} ---------------

def token_db_path(cp):
    return cp["notifier"].get("token_db", "/var/lib/analog-notifier/tokens.json")


def load_tokens(cp):
    p = Path(token_db_path(cp))
    if not p.exists():
        return {}
    with p.open() as f:
        return json.load(f)


def save_tokens(cp, tokens):
    p = Path(token_db_path(cp))
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("w") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        json.dump(tokens, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())


# --- coalescing: one ping per hash per window -------------------------------

def coalesce_path(cp):
    return cp["notifier"].get("coalesce_state", "/var/lib/analog-notifier/coalesce.json")


def coalesce_allow(cp, h):
    """Return True if hash h may be pinged now (outside its window)."""
    window = int(cp["notifier"].get("coalesce_window_seconds", "60"))
    p = Path(coalesce_path(cp))
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(p), os.O_RDWR | os.O_CREAT, 0o640)
    with os.fdopen(fd, "r+") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        f.seek(0)
        try:
            state = json.loads(f.read() or "{}")
        except json.JSONDecodeError:
            state = {}
        now = time.time()
        last = state.get(h, 0)
        if now - last < window:
            return False
        state[h] = now
        f.seek(0)
        f.truncate()
        json.dump(state, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    return True


# --- APNs send --------------------------------------------------------------

def send_apns(cp, device_token, recipient_hash):
    """Send a mutable-content push. Envelope payload is TODO (content-free)."""
    import httpx
    import jwt

    a = cp["apns"]
    team_id, key_id, bundle_id, key_path = (
        a["team_id"], a["key_id"], a["bundle_id"], a["key_path"],
    )
    host = a.get("host", "api.push.apple.com")

    with open(key_path, "rb") as f:
        key_bytes = f.read()
    now = int(time.time())
    provider_jwt = jwt.encode(
        {"iss": team_id, "iat": now},
        key_bytes,
        algorithm="ES256",
        headers={"kid": key_id},
    )

    # TODO: replace this content-free alert with the E2E-encrypted envelope
    # pulled from the inbound LXMF message (ciphertext only). The NSE on the
    # device decrypts it; this server never has plaintext.
    payload = {
        "aps": {
            "mutable-content": 1,
            "alert": {"title": "Analog", "body": "New message"},
        },
        # "envelope": <ciphertext>,         # TODO (memo section 05)
        "recipient": recipient_hash,        # debug only — drop before prod
    }

    url = f"https://{host}/3/device/{device_token}"
    headers = {
        "authorization": f"bearer {provider_jwt}",
        "apns-topic": bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "5",
    }
    with httpx.Client(http2=True, timeout=15) as c:
        r = c.post(url, json=payload, headers=headers)
    if r.status_code != 200:
        log(f"APNs {r.status_code} for {recipient_hash[:8]}…: {r.text}")
    else:
        log(f"APNs ping sent for {recipient_hash[:8]}…")
    return r.status_code == 200


# --- trigger mode (lxmd on_inbound) -----------------------------------------

def trigger(args, cp):
    if not configured(cp):
        log("not configured — skipping ping (edit /etc/analog/notifier.conf)")
        return 0
    h = args.recipient_hash
    if not h and args.from_stdin:
        # TODO: parse the recipient destination hash from the LXMF message
        # bytes lxmd pipes on stdin (use the installed `lxmf` library). For
        # now this is a stub; fall through with no hash -> exit.
        data = sys.stdin.buffer.read()
        log(f"on_inbound received {len(data)} bytes; recipient-hash parse TODO")
        return 0
    if not h:
        log("no recipient hash; nothing to ping")
        return 0
    h = h.lower()
    if not coalesce_allow(cp, h):
        log(f"coalesced (within window) for {h[:8]}…")
        return 0
    tokens = load_tokens(cp)
    token = tokens.get(h)
    if not token:
        log(f"no token registered for {h[:8]}… — mail waits at the node")
        return 0
    send_apns(cp, token, h)
    return 0


# --- register mode (daemon) -------------------------------------------------

def register(args, cp):
    if not configured(cp):
        log("not configured — registration daemon staying dormant "
            "(drop the .p8, fill /etc/analog/notifier.conf, restart)")
        return 0
    try:
        import RNS  # noqa: F401
    except ImportError:
        log("RNS library not available — cannot run registration daemon")
        return 1

    # TODO: implement against the rns python API. Sketch:
    #   reticulum = RNS.Reticulum(configdir=<rnsconfig>)
    #   dest = RNS.Destination(app_name="analog", aspects=["notifier","register"],
    #                          direction=RNS.Destination.IN,
    #                          creates_link=True)
    #   dest.set_link_established_callback(on_link)
    #   dest.announce()
    #   ... on link: receive {lxmf_hash, apns_token} JSON, verify signature
    #       (memo section 08 — registration must be authenticated), save_tokens.
    #   loop forever (announce periodically).
    log("registration daemon: RNS wiring not yet implemented (TODO) — exiting")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Analog APNs Notifier (skeleton)")
    ap.add_argument("--config", default=DEFAULT_CONF)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--register", action="store_true",
                   help="run the token-registration daemon")
    g.add_argument("--trigger", action="store_true",
                   help="handle one lxmd on_inbound event (send a ping)")
    ap.add_argument("--recipient-hash", help="recipient LXMF destination hash (hex)")
    ap.add_argument("--from-stdin", action="store_true",
                    help="read the inbound LXMF message from stdin")
    args = ap.parse_args()

    cp = load_config(args.config)
    if args.register:
        sys.exit(register(args, cp))
    sys.exit(trigger(args, cp))


if __name__ == "__main__":
    main()
PYEOF
chmod 755 "${NOTIFIER_INSTALL_DIR}/analog_notifier.py"
chown "root:${RNS_GROUP}" "${NOTIFIER_INSTALL_DIR}/analog_notifier.py"

# ---------------------------------------------------------------------------
# 4. on_inbound trigger script (lxmd calls this per received message)
# ---------------------------------------------------------------------------
log "Writing ${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh"
cat > "${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh" <<'SH'
#!/bin/sh
# lxmd --on-inbound hook. lxmd invokes this when a message is received.
# Forwards the inbound message (on stdin) to the Analog notifier.
#
# TODO: confirm lxmd's on_inbound invocation contract (stdin bytes vs. file
# path vs. args) and adjust the forwarding below. Currently assumes stdin.
exec /opt/analog-notifier/analog_notifier.py --config /etc/analog/notifier.conf \
    --trigger --from-stdin
SH
chmod 755 "${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh"
chown "root:${RNS_GROUP}" "${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh"

# ---------------------------------------------------------------------------
# 5. Notifier config (placeholders — operator fills + drops the .p8)
# ---------------------------------------------------------------------------
log "Writing ${NOTIFIER_CONF_DIR}/notifier.conf"
cat > "${NOTIFIER_CONF_DIR}/notifier.conf" <<EOF
# Analog APNs Notifier configuration.
# Fill the [apns] block and drop your APNs .p8 key at the key_path, then
# restart analog-notifier and lxmd. Until then both stay dormant/safe.

[notifier]
# Where {lxmf_hash: apns_token} bindings are stored (written by --register).
token_db    = ${NOTIFIER_STATE_DIR}/tokens.json
# Per-hash coalescing state (last-pinged timestamps).
coalesce_state        = ${NOTIFIER_STATE_DIR}/coalesce.json
# One ping per recipient per this many seconds (burst -> single ping).
coalesce_window_seconds = 60
# RNS config dir of the shared rnsd instance (for the --register daemon).
rnsconfig   = ${RNS_CONFIG_DIR}

[apns]
# Apple Developer: Keys > APNs Auth Key (.p8). Supply these to activate.
team_id     = REPLACE_ME
key_id      = REPLACE_ME
bundle_id   = REPLACE_ME       # e.g. com.analog.app
key_path    = ${NOTIFIER_CONF_DIR}/AuthKey_REPLACE_ME.p8
# api.push.apple.com (prod) or api.development.push.apple.com (sandbox).
host        = api.push.apple.com
EOF
chown "root:${RNS_GROUP}" "${NOTIFIER_CONF_DIR}/notifier.conf"
chmod 640 "${NOTIFIER_CONF_DIR}/notifier.conf"

if [ ! -f "${NOTIFIER_STATE_DIR}/tokens.json" ]; then
    echo '{}' > "${NOTIFIER_STATE_DIR}/tokens.json"
    chown "${RNS_USER}:${RNS_GROUP}" "${NOTIFIER_STATE_DIR}/tokens.json"
    chmod 640 "${NOTIFIER_STATE_DIR}/tokens.json"
fi

# ---------------------------------------------------------------------------
# 6. lxmd config (propagation node, on_inbound -> notifier trigger)
# ---------------------------------------------------------------------------
LXMD_CONFIG_FILE="${LXMD_CONFIG_DIR}/config"
if [ -f "${LXMD_CONFIG_FILE}" ]; then
    BACKUP="${LXMD_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backing up existing lxmd config -> ${BACKUP}"
    cp -a "${LXMD_CONFIG_FILE}" "${BACKUP}"
fi

log "Writing lxmd config at ${LXMD_CONFIG_FILE}"
cat > "${LXMD_CONFIG_FILE}" <<EOF
# lxmd configuration — Analog propagation node + notifier trigger.
# Generated by install-analog-notifier.sh.
# See: lxmd --exampleconfig

[propagation]
  # Must be Yes to run a propagation node (store-and-forward for offline users).
  enable_node = Yes
  announce_at_start = yes
  autopeer = yes
  autopeer_maxdepth = 4
  # Max accepted transfer size in KB.
  propagation_transfer_max_accepted_size = 256

[lxmf]
  display_name = Analog Propagation Node
  # Run the notifier trigger when a message is received.
  # TODO: verify on_inbound fires for messages accepted into the propagation
  # store (not only locally-delivered). If not, poll the store directory.
  on_inbound = ${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh

[logging]
  loglevel = 4
EOF
chown "${RNS_USER}:${RNS_GROUP}" "${LXMD_CONFIG_FILE}"
chmod 640 "${LXMD_CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 7. OpenRC init script: lxmd
# ---------------------------------------------------------------------------
LXMD_INIT="/etc/init.d/lxmd"
log "Writing OpenRC init script: ${LXMD_INIT}"
cat > "${LXMD_INIT}" <<EOF
#!/sbin/openrc-run
# LXMF Propagation Node Daemon (Analog)

name="LXMF Propagation Node (Analog)"
description="lxmd store-and-forward propagation node + notifier trigger"

command="${LXMD_BIN}"
command_args="--service --config ${LXMD_CONFIG_DIR} --rnsconfig ${RNS_CONFIG_DIR} --propagation-node"
command_user="${RNS_USER}:${RNS_GROUP}"

supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0

output_log="/var/log/lxmd.log"
error_log="/var/log/lxmd.log"

depend() {
    need rnsd net
    after firewall
}

start_pre() {
    checkpath -f -m 0640 -o ${RNS_USER}:${RNS_GROUP} "\${output_log}"
}
EOF
chmod +x "${LXMD_INIT}"

# ---------------------------------------------------------------------------
# 8. OpenRC init script: analog-notifier (registration daemon)
# ---------------------------------------------------------------------------
NOTIFIER_INIT="/etc/init.d/${NOTIFIER_NAME}"
log "Writing OpenRC init script: ${NOTIFIER_INIT}"
cat > "${NOTIFIER_INIT}" <<EOF
#!/sbin/openrc-run
# Analog APNs Notifier — token registration daemon

name="Analog APNs Notifier"
description="Receives {lxmf_hash, apns_token} bindings over RNS"

command="/usr/bin/env"
command_args="python3 ${NOTIFIER_INSTALL_DIR}/analog_notifier.py --config ${NOTIFIER_CONF_DIR}/notifier.conf --register"
command_user="${RNS_USER}:${RNS_GROUP}"

supervisor="supervise-daemon"
# The daemon self-exits while unconfigured (dormant); back off so it doesn't
# hammer once configured-and-restarting during bring-up.
respawn_delay=15
respawn_max=0

output_log="${NOTIFIER_LOG_DIR}/notifier.log"
error_log="${NOTIFIER_LOG_DIR}/notifier.log"

depend() {
    need rnsd net
    after lxmd firewall
}

start_pre() {
    checkpath -d -m 0750 -o ${RNS_USER}:${RNS_GROUP} "${NOTIFIER_LOG_DIR}"
    checkpath -f -m 0640 -o ${RNS_USER}:${RNS_GROUP} "\${output_log}"
}
EOF
chmod +x "${NOTIFIER_INIT}"

# ---------------------------------------------------------------------------
# 9. Enable + start
# ---------------------------------------------------------------------------
log "Enabling lxmd and ${NOTIFIER_NAME} at the 'default' runlevel"
rc-update add lxmd default
rc-update add "${NOTIFIER_NAME}" default

if rc-service rnsd status >/dev/null 2>&1; then
    log "Starting lxmd..."
    rc-service lxmd restart || rc-service lxmd start
else
    warn "rnsd is not running — start it first, then: rc-service lxmd start; rc-service ${NOTIFIER_NAME} start"
fi

log "Starting ${NOTIFIER_NAME} (dormant until /etc/analog/notifier.conf is filled)..."
rc-service "${NOTIFIER_NAME}" restart || rc-service "${NOTIFIER_NAME}" start || true

sleep 2
rc-service lxmd status || true
rc-service "${NOTIFIER_NAME}" status || true

cat <<EOF

------------------------------------------------------------
 Analog notifier stack installed alongside rnsd.

   lxmd service          : rc-service lxmd <status|restart|stop>
   notifier service      : rc-service ${NOTIFIER_NAME} <status|restart|stop>
   notifier script       : ${NOTIFIER_INSTALL_DIR}/analog_notifier.py
   on_inbound trigger    : ${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh
   notifier config       : ${NOTIFIER_CONF_DIR}/notifier.conf
   token DB              : ${NOTIFIER_STATE_DIR}/tokens.json
   coalesce state        : ${NOTIFIER_STATE_DIR}/coalesce.json
   lxmd config           : ${LXMD_CONFIG_FILE}
   logs                  : tail -f /var/log/lxmd.log
                            tail -f ${NOTIFIER_LOG_DIR}/notifier.log

 NEXT STEPS — activate the notifier:
   1. From Apple Developer > Keys > APNs Auth Key, download the .p8 and note
      the Key ID and your Team ID.
   2. Copy it:  cp AuthKey_<KEYID>.p8 ${NOTIFIER_CONF_DIR}/
      chown root:${RNS_GROUP} ${NOTIFIER_CONF_DIR}/AuthKey_<KEYID>.p8
      chmod 640 ${NOTIFIER_CONF_DIR}/AuthKey_<KEYID>.p8
   3. Edit ${NOTIFIER_CONF_DIR}/notifier.conf: fill team_id, key_id, bundle_id,
      and set key_path to the .p8 you just dropped.
      (Use host = api.development.push.apple.com for sandbox builds.)
   4. rc-service ${NOTIFIER_NAME} restart && rc-service lxmd restart

 SKELETON TODO (see script headers + the memo):
   - lxmd on_inbound contract (stdin/path/args) — verify + parse recipient hash.
   - Encrypted-envelope payload + NSE (memo section 05) — currently content-free.
   - Registration-packet authentication over RNS (memo section 08).
   - on_inbound firing for propagation-store accepts vs. local delivery.

 The propagation node (lxmd) is live now and holds offline mail regardless of
 the notifier — that part does not depend on APNs being configured.
------------------------------------------------------------
EOF

} # end of main()

main "$@"