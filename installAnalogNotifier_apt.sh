#!/bin/bash
#
# install-analog-notifier.sh  (Debian / Ubuntu variant)
#
# Companion to installRnsd_apt.sh. Sets up the two server-side pieces the
# iOS background wake-up design needs alongside a running rnsd:
#
#   1. lxmd  — the LXMF Propagation Node daemon (store-and-forward). Holds
#              offline messages until the recipient's app acks. This is the
#              substrate; without it there is nothing to wake the phone for.
#              Runs against the shared rnsd instance (--rnsconfig).
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
#   - The notifier NEVER has message plaintext. It learns only the recipient
#     destination hash (to look up the token) and, in the full design, a small
#     E2E-encrypted envelope (ciphertext) to carry in the push. Ciphertext is
#     not content.
#   - A missed ping is a delayed message, never a lost one: lxmd holds the
#     message until ack. This service only buys latency back.
#
# Status: SKELETON. The ops scaffolding (units, config, paths, coalescing, APNs
# JWT send, on_inbound wiring) is real; the lxmd on_inbound contract, the
# encrypted-envelope/NSE payload, and registration-packet authentication are
# marked TODO in analog_notifier.py and must be verified/completed before prod.
#
# Usage:  sudo ./install-analog-notifier.sh
# Requires: rnsd already installed by installRnsd_apt.sh (shares its user,
#           config dir, and RNS instance socket).
#

set -euo pipefail

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

# All work happens inside main() and main is only invoked on the final line.
# If this script is truncated mid-download (curl | sudo bash), bash fails to
# parse an incomplete function body before main is called, so nothing partial
# runs.
main() {

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (try: sudo $0)"
    exit 1
fi

# Debian-family + systemd
if ! command -v apt-get >/dev/null 2>&1; then
    err "apt-get not found. Use installAnalogNotifier_apk.sh on Alpine."
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl not found. This script requires a systemd-based system."
    exit 1
fi

# Depends on rnsd being installed (shares its user + RNS instance).
if [ ! -d "${RNS_CONFIG_DIR}" ]; then
    err "Reticulum config dir ${RNS_CONFIG_DIR} not found."
    err "Run installRnsd_apt.sh first — this installer shares the rnsd user and RNS instance."
    exit 1
fi
if ! id -u "${RNS_USER}" >/dev/null 2>&1; then
    err "Service user '${RNS_USER}' not found. Run installRnsd_apt.sh first."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. System + Python dependencies
# ---------------------------------------------------------------------------
log "Updating apt index and installing system dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates python3 python3-pip

# lxmd ships with the lxmf pip package. The rnsd installer already installed
# it, but re-ensure (idempotent) and locate the binary.
PIP_FLAGS=""
if find /usr/lib/python3*/EXTERNALLY-MANAGED -maxdepth 1 2>/dev/null | grep -q .; then
    PIP_FLAGS="--break-system-packages"
fi

log "Ensuring lxmf (provides lxmd) is installed..."
# shellcheck disable=SC2086
pip3 install --upgrade ${PIP_FLAGS} lxmf

LXMD_BIN="$(command -v lxmd || true)"
for candidate in /usr/local/bin/lxmd /usr/bin/lxmd; do
    [ -n "${LXMD_BIN}" ] && break
    [ -x "${candidate}" ] && LXMD_BIN="${candidate}"
done
if [ -z "${LXMD_BIN}" ]; then
    err "lxmd binary not found after installing lxmf."
    exit 1
fi
log "lxmd installed at ${LXMD_BIN}"

# Notifier Python deps:
#   PyJWT  — ES256-sign the APNs provider JWT with the .p8 key.
#   httpx  — APNs requires HTTP/2; httpx with the h2 backend does it.
log "Installing notifier Python deps (PyJWT, httpx[http2])..."
# shellcheck disable=SC2086
pip3 install --upgrade ${PIP_FLAGS} "PyJWT" "httpx[http2]"

# ---------------------------------------------------------------------------
# 2. Directory layout
# ---------------------------------------------------------------------------
log "Creating notifier directories..."
mkdir -p "${NOTIFIER_INSTALL_DIR}" \
         "${NOTIFIER_CONF_DIR}" \
         "${NOTIFIER_STATE_DIR}" \
         "${NOTIFIER_LOG_DIR}" \
         "${LXMD_CONFIG_DIR}"

# Scripts: root-owned, group-readable + executable by reticulum.
chown -R "root:${RNS_GROUP}" "${NOTIFIER_INSTALL_DIR}" "${NOTIFIER_CONF_DIR}"
chmod 755 "${NOTIFIER_INSTALL_DIR}"
chmod 750 "${NOTIFIER_CONF_DIR}"

# State + logs: owned by the reticulum service user (lxmd and the notifier
# both run as it, so they can read config and write state).
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
    # Open for read+write so we can lock the same handle.
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
        # Exit 0 so systemd marks us inactive(exited), not failed. The operator
        # restarts after configuring.
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

# Empty token DB so the notifier has a valid file from the start.
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
# 7. systemd unit: lxmd
# ---------------------------------------------------------------------------
LXMD_UNIT="/etc/systemd/system/lxmd.service"
log "Writing systemd unit: ${LXMD_UNIT}"
cat > "${LXMD_UNIT}" <<EOF
[Unit]
Description=LXMF Propagation Node Daemon (Analog)
After=rnsd.service network-online.target
Wants=rnsd.service network-online.target
Requires=rnsd.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=${RNS_USER}
Group=${RNS_GROUP}
ExecStart=${LXMD_BIN} --service --config ${LXMD_CONFIG_DIR} --rnsconfig ${RNS_CONFIG_DIR} --propagation-node

StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${RNS_HOME} ${NOTIFIER_STATE_DIR} ${NOTIFIER_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${LXMD_UNIT}"

# ---------------------------------------------------------------------------
# 8. systemd unit: analog-notifier (registration daemon)
# ---------------------------------------------------------------------------
NOTIFIER_UNIT="/etc/systemd/system/${NOTIFIER_NAME}.service"
log "Writing systemd unit: ${NOTIFIER_UNIT}"
cat > "${NOTIFIER_UNIT}" <<EOF
[Unit]
Description=Analog APNs Notifier (token registration daemon)
After=rnsd.service lxmd.service network-online.target
Wants=rnsd.service lxmd.service network-online.target
Requires=rnsd.service

[Service]
Type=simple
# The daemon self-exits 0 while unconfigured (dormant). Don't crash-loop it.
Restart=on-failure
RestartSec=15
User=${RNS_USER}
Group=${RNS_GROUP}
ExecStart=/usr/bin/env python3 ${NOTIFIER_INSTALL_DIR}/analog_notifier.py --config ${NOTIFIER_CONF_DIR}/notifier.conf --register

StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${NOTIFIER_STATE_DIR} ${NOTIFIER_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${NOTIFIER_UNIT}"

# ---------------------------------------------------------------------------
# 9. Enable + start
# ---------------------------------------------------------------------------
log "Reloading systemd..."
systemctl daemon-reload
systemctl enable lxmd.service "${NOTIFIER_NAME}.service"

# lxmd is real and ready — start it now.
if systemctl is-active --quiet rnsd.service; then
    log "Starting lxmd..."
    systemctl restart lxmd.service
else
    warn "rnsd.service is not active — start it first, then: systemctl start lxmd ${NOTIFIER_NAME}"
fi

# The notifier daemon stays dormant until configured (exits 0 when placeholders
# are present). Start it anyway so it flips to active once configured + restarted.
log "Starting ${NOTIFIER_NAME} (dormant until /etc/analog/notifier.conf is filled)..."
systemctl restart "${NOTIFIER_NAME}.service" || true

sleep 2
systemctl --no-pager --full status lxmd.service || true
systemctl --no-pager --full status "${NOTIFIER_NAME}.service" || true

cat <<EOF

------------------------------------------------------------
 Analog notifier stack installed alongside rnsd.

   lxmd service          : lxmd.service
   notifier service      : ${NOTIFIER_NAME}.service
   notifier script       : ${NOTIFIER_INSTALL_DIR}/analog_notifier.py
   on_inbound trigger    : ${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh
   notifier config       : ${NOTIFIER_CONF_DIR}/notifier.conf
   token DB              : ${NOTIFIER_STATE_DIR}/tokens.json
   coalesce state        : ${NOTIFIER_STATE_DIR}/coalesce.json
   lxmd config           : ${LXMD_CONFIG_FILE}
   logs                  : journalctl -u lxmd -f
                            journalctl -u ${NOTIFIER_NAME} -f

 NEXT STEPS — activate the notifier:
   1. From Apple Developer > Keys > APNs Auth Key, download the .p8 and note
      the Key ID and your Team ID.
   2. Copy it:  sudo cp AuthKey_<KEYID>.p8 ${NOTIFIER_CONF_DIR}/
      sudo chown root:${RNS_GROUP} ${NOTIFIER_CONF_DIR}/AuthKey_<KEYID>.p8
      sudo chmod 640 ${NOTIFIER_CONF_DIR}/AuthKey_<KEYID>.p8
   3. Edit ${NOTIFIER_CONF_DIR}/notifier.conf: fill team_id, key_id, bundle_id,
      and set key_path to the .p8 you just dropped.
      (Use host = api.development.push.apple.com for sandbox builds.)
   4. sudo systemctl restart ${NOTIFIER_NAME} lxmd

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