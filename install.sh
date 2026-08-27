#!/bin/sh
#
# install.sh  —  combined Reticulum (rnsd) + optional Analog notifier installer
#
# One self-contained POSIX sh script for both Debian/Ubuntu (apt + systemd)
# and Alpine (apk + OpenRC). Asks two questions up front:
#
#   1. Select the environment        (APT / APK)   — auto-detected default
#   2. Install the Analog notifier?  (Yes / No)    — defaults to Yes
#
# Then installs rnsd, and (if Yes) the Analog notifier stack (lxmd +
# analog-notifier) alongside it. The per-OS originals (installRnsd_apt.sh,
# installRnsd_apk.sh, installAnalogNotifier_apt.sh, installAnalogNotifier_apk.sh)
# are kept untouched as a safety net.
#
# Non-interactive overrides (for `curl | sh` / CI):
#   RNS_ENV=apt|apk               — skip the environment prompt
#   RNS_INSTALL=full|rnsd|notifier — skip the "what to install" prompt
#   RNS_NOTIFIER=yes|no           — legacy alias (yes→full, no→rnsd)
#
# DESIGN: a single code path per installer, branched only where apt/apk or
# systemd/OpenRC genuinely differ. Two switches drive the branches:
#   PM   = apt | apk        (package manager + package names)
#   INIT = systemd | openrc (service commands + service definitions)
# They are derived from the environment choice in main(), so every install
# function is OS-agnostic except for a few clearly-marked `if [ "$PM" ... ]`
# / `if [ "$INIT" ... ]` blocks.
#
# PHASE STRUCTURE (same on both OSes, so you always know where you are):
#
#   rnsd install:   PREFLIGHT, then 6 phases
#     PHASE 1 — System dependencies
#     PHASE 2 — Service user
#     PHASE 3 — Install rns + lxmf via pip
#     PHASE 4 — Write RNS config (stop existing first)
#     PHASE 5 — Write service definition (systemd unit / OpenRC init)
#     PHASE 6 — Enable + start + verify
#
#   notifier install:  PREFLIGHT, then 6 phases
#     PHASE 1 — System + Python dependencies
#     PHASE 2 — Service user + directory layout (+ read-only store ACL)
#     PHASE 3 — Write notifier code + config
#     PHASE 4 — Write lxmd config
#     PHASE 5 — Write service definitions (lxmd + notifier)
#     PHASE 6 — Enable + start + verify
#
#   APNs keys (separate step, once per environment, from a local copy of this
#   script — never via curl | sh, the key must not travel with the installer):
#     sudo sh install.sh --install-key AuthKey_<KEYID>.p8 --team-id <ID> \
#          --bundle-id app.analog.app --env production
#     sudo sh install.sh --install-key AuthKey_<KEYID>.p8 --team-id <ID> \
#          --bundle-id app.analog.dev --env sandbox
#   A device token only works against the environment its build was signed
#   for, so tokens.json records the env per registration and the notifier
#   picks the matching [apns.<env>] profile.
#
# SECURITY MODEL for the APNs .p8 (team-wide, non-expiring signing key):
#   - The notifier runs as its own user (analog-notifier). rnsd and lxmd — the
#     internet-facing processes — run as `reticulum` and cannot read the key.
#   - The notifier does not run inside lxmd (no on_inbound hook); it watches
#     lxmd's message store through a read-only POSIX ACL and reads only the
#     16-byte recipient-hash header of each stored message.
#   - On systemd >= 250 the key is stored as an encrypted credential
#     (systemd-creds, host/TPM2-bound) and decrypted only into the service's
#     private credentials mount. Elsewhere it is a 0400 file owned by the
#     service user.
#   - The notifier unit is sandboxed (ProtectSystem=strict, no capabilities,
#     syscall filter, IP/unix sockets only).
#
# Each phase prints a live banner and is marked in the source with a
# greppable `# ═══ PHASE n — title ═══` header. Find any phase with:
#   grep -n "PHASE" install.sh
#
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --install-key AuthKey_XXXX.p8 --team-id T --bundle-id B --env production|sandbox
#   curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh | sudo bash
#   wget -qO- https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh | sh
#
# Tested on:
#   - Debian 11/12/13, Ubuntu 22.04/24.04   (systemd, PEP 668 aware)
#   - Alpine 3.19+                           (OpenRC, supervise-daemon)
#

set -eu

# ---------- Configurable knobs ----------------------------------------------
RNS_USER="${RNS_USER:-reticulum}"
RNS_GROUP="${RNS_GROUP:-reticulum}"
RNS_HOME="${RNS_HOME:-/var/lib/reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-${RNS_HOME}/.reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-${RNS_HOME}/.lxmd}"
SERVICE_NAME="rnsd"

NOTIFIER_NAME="analog-notifier"
NOTIFIER_INSTALL_DIR="${NOTIFIER_INSTALL_DIR:-/opt/analog-notifier}"
NOTIFIER_CONF_DIR="${NOTIFIER_CONF_DIR:-/etc/analog}"
NOTIFIER_STATE_DIR="${NOTIFIER_STATE_DIR:-/var/lib/analog-notifier}"
NOTIFIER_LOG_DIR="${NOTIFIER_LOG_DIR:-/var/log/analog-notifier}"
# Dedicated unprivileged user for the notifier (the only reader of the APNs key).
NOTIFIER_USER="${NOTIFIER_USER:-analog-notifier}"
NOTIFIER_GROUP="${NOTIFIER_GROUP:-analog-notifier}"
# lxmd's propagation message store — the notifier watches this read-only.
# (LXMRouter appends /lxmf to lxmd's storage dir.)
LXMD_STORE_DIR="${LXMD_CONFIG_DIR}/storage/lxmf/messagestore"
# Where the APNs keys end up (one per environment, production|sandbox):
#   encrypted systemd credential ${NOTIFIER_CONF_DIR}/apns_p8_<env>.cred (preferred)
#   or 0400 file                 ${NOTIFIER_CONF_DIR}/apns_<env>.p8
# ----------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

# Phase tracker — prints a clear, numbered banner at each install step so the
# operator can follow exactly where the script is and what it is doing. Each
# installer resets PHASE_NUM and sets PHASE_TOTAL before its first phase().
PHASE_NUM=0
PHASE_TOTAL=""
phase() {
    PHASE_NUM=$((PHASE_NUM + 1))
    if [ -n "${PHASE_TOTAL}" ]; then
        printf '\n\033[1;36m━━━ [PHASE %s/%s] %s ━━━\033[0m\n' \
            "$PHASE_NUM" "$PHASE_TOTAL" "$1"
    else
        printf '\n\033[1;36m━━━ [PHASE %s] %s ━━━\033[0m\n' \
            "$PHASE_NUM" "$1"
    fi
}

# ============================================================================
# OS abstractions — the only place that knows about apt/apk or systemd/OpenRC.
# PM and INIT are set in main() from the environment choice; PIP_FLAGS and the
# dep lists are resolved once there too. Everything below calls these helpers.
# ============================================================================

# package manager
pkg_update() {
    if [ "$PM" = apt ]; then
        apt-get update -y
    else
        apk update || warn "apk update reported errors (likely a stale/unreachable mirror) — continuing"
    fi
}

# shellcheck disable=SC2086
pkg_install() {
    if [ "$PM" = apt ]; then
        apt-get install -y --no-install-recommends "$@"
    else
        apk add --no-cache "$@"
    fi
}

# Best-effort single-package install (stderr suppressed). Used in the native-
# dep probe loop where a missing package is expected, not fatal.
pkg_install_quiet() {
    if [ "$PM" = apt ]; then
        apt-get install -y --no-install-recommends "$@" 2>/dev/null
    else
        apk add --no-cache "$@" 2>/dev/null
    fi
}

# pip. PIP_FLAGS is resolved lazily on first use so the PEP 668
# EXTERNALLY-MANAGED marker is probed *after* python3 has been installed.
PIP_FLAGS_RESOLVED=""
resolve_pip_flags() {
    [ -n "${PIP_FLAGS_RESOLVED}" ] && return
    PIP_FLAGS_RESOLVED=1
    PIP_FLAGS=""
    if [ "${PM}" = apk ]; then
        PIP_FLAGS="--break-system-packages"
    elif find /usr/lib/python3*/EXTERNALLY-MANAGED -maxdepth 1 2>/dev/null | grep -q .; then
        log "Detected PEP 668 EXTERNALLY-MANAGED marker — using --break-system-packages"
        PIP_FLAGS="--break-system-packages"
    fi
}
# shellcheck disable=SC2086
pip_install() { resolve_pip_flags; pip3 install --upgrade $PIP_FLAGS "$@"; }

# Install Python modules only if they cannot be imported. Prefers the distro
# package (arg format: module:distro-pkg:pip-pkg) and falls back to pip
# WITHOUT --upgrade — pip refuses to replace Debian-installed packages
# ("no RECORD file"), so never let it try.
ensure_py_modules() {
    for spec in "$@"; do
        mod="${spec%%:*}"; rest="${spec#*:}"; distro_pkg="${rest%%:*}"; pip_pkg="${rest#*:}"
        if python3 -c "import ${mod}" 2>/dev/null; then
            log "  ${mod}: already available"
            continue
        fi
        if pkg_install_quiet "${distro_pkg}" && python3 -c "import ${mod}" 2>/dev/null; then
            log "  ${mod}: installed ${distro_pkg} via ${PM}"
            continue
        fi
        log "  ${mod}: not packaged — installing ${pip_pkg} via pip"
        resolve_pip_flags
        # shellcheck disable=SC2086
        pip3 install $PIP_FLAGS "${pip_pkg}"
    done
}

# Locate an installed executable, falling back to the two paths pip commonly
# uses on minimal Debian containers where /usr/local/bin may not be on PATH.
find_bin() {
    b="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$b" ]; then
        for c in /usr/local/bin/"$1" /usr/bin/"$1"; do
            [ -x "$c" ] && { b="$c"; break; }
        done
    fi
    echo "$b"
}

# service commands (INIT = systemd | openrc). Predicates are meant for use
# inside `if`/`||` so set -e does not fire on a non-active/non-zero result.
svc_is_active() {
    if [ "$INIT" = systemd ]; then
        systemctl is-active --quiet "$1.service" 2>/dev/null
    else
        rc-service "$1" status >/dev/null 2>&1
    fi
}
svc_reload()  { [ "$INIT" = systemd ] && systemctl daemon-reload || true; }
svc_enable()  {
    if [ "$INIT" = systemd ]; then systemctl enable "$1.service"
    else rc-update add "$1" default; fi
}
svc_restart() {
    if [ "$INIT" = systemd ]; then systemctl restart "$1.service"
    else rc-service "$1" restart; fi
}
svc_start()   {
    if [ "$INIT" = systemd ]; then systemctl start "$1.service"
    else rc-service "$1" start; fi
}
svc_stop()    {
    if [ "$INIT" = systemd ]; then systemctl stop "$1.service" 2>/dev/null || true
    else rc-service "$1" stop 2>/dev/null || true; fi
}
svc_status()  {
    if [ "$INIT" = systemd ]; then systemctl --no-pager --full status "$1.service"
    else rc-service "$1" status; fi
}
# Restart if running, otherwise start. Returns the service's exit status.
svc_restart_or_start() {
    if svc_is_active "$1"; then log "Restarting $1..."; svc_restart "$1"
    else log "Starting $1..."; svc_start "$1"; fi
}

# ============================================================================
# Shared content writers (identical across apt/apk — only the surrounding
# package-manager / init-system glue differs). These write the OS-agnostic
# config files and the notifier Python body; the installers call them.
# ============================================================================

# RNS daemon config. Caller sets: CONFIG_FILE, HOSTNAME_SLUG, RNS_USER, RNS_GROUP.
write_rns_config() {
    log "Writing config at ${CONFIG_FILE}"
    cat > "${CONFIG_FILE}" <<EOF
# Reticulum configuration
# Generated by install.sh
# See https://markqvist.github.io/Reticulum/manual/ for full reference.

[reticulum]

  # Route traffic for other peers, pass announces, serve path requests.
  # Enable this for always-on nodes (recommended for servers).
  enable_transport = Yes

  # Let other local programs share this daemon's Reticulum instance
  # via a domain socket named after the host.
  share_instance = Yes
  instance_name = ${HOSTNAME_SLUG}

  # Discover and use interface info advertised by other Transport Instances.
  discover_interfaces = yes


[logging]
  # 0=critical .. 4=info (default) .. 6=debug .. 7=extreme
  loglevel = 4


[interfaces]

  [[Default Interface]]
    type = AutoInterface
    enabled = Yes

  [[Local TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 0.0.0.0
    listen_port = 4242

  [[Beleth RNS Hub]]
    type = TCPClientInterface
    enabled = yes
    target_host = rns.beleth.net
    target_port = 4242

  [[Ether Whisperer]]
    type = TCPClientInterface
    enabled = yes
    target_host = 132.145.75.143
    target_port = 4242

  [[Catz Node (TCP)]]
    type = TCPClientInterface
    enabled = yes
    target_host = 77.37.146.243
    target_port = 4242

  [[RMAP]]
    type = TCPClientInterface
    enabled = yes
    target_host = rmap.world
    target_port = 4242

  [[RNS_Transport_US-East]]
    type = TCPClientInterface
    enabled = yes
    target_host = 45.77.109.86
    target_port = 4965

  [[bnZ-NODE01 (Gothenburg SE)]]
    type = BackboneInterface
    enabled = yes
    remote = 91.207.113.250
    target_port = 4242

  [[Pleiades Inc.]]
    type = BackboneInterface
    enabled = yes
    remote = ahara.jp.net
    target_port = 4242
EOF
    chown "${RNS_USER}:${RNS_GROUP}" "${CONFIG_FILE}"
    chmod 640 "${CONFIG_FILE}"
}

# analog_notifier.py — byte-identical on both OSes.
# Caller sets: NOTIFIER_INSTALL_DIR.
write_notifier_python() {
    log "Writing ${NOTIFIER_INSTALL_DIR}/analog_notifier.py"
    cat > "${NOTIFIER_INSTALL_DIR}/analog_notifier.py" <<'PYEOF'
#!/usr/bin/env python3
"""Analog APNs Notifier.

Modes:
  --daemon                 Long-running service (runs as its own user).
                           Watches lxmd's propagation message store; for every
                           newly stored message it reads the 16-byte recipient
                           destination hash from the file header (and nothing
                           else), coalesces, looks up the APNs token and sends
                           a content-free mutable-content push.
  --trigger --recipient-hash H
                           One-shot manual ping (for testing).

ENVIRONMENTS
  A device token only works against the APNs environment its build was
  signed for: app.analog.app -> production (api.push.apple.com),
  app.analog.dev -> sandbox (api.development.push.apple.com). The config
  therefore has one [apns.production] and one [apns.sandbox] profile, each
  with its own key, and every token-DB entry records which one it belongs to:
      "<lxmf_hash>": "<token>"                          # production
      "<lxmf_hash>": {"token": "<token>", "env": "sandbox"}

PRIVILEGE MODEL
  - The daemon runs as the dedicated `analog-notifier` user. The network-facing
    daemons (rnsd, lxmd — user `reticulum`) cannot read the APNs key, and the
    notifier cannot read rnsd's or lxmd's identities: it has a read-only POSIX
    ACL on the message-store directory only.
  - The APNs .p8 arrives either as a systemd encrypted credential
    ($CREDENTIALS_DIRECTORY/apns_p8_<env> — plaintext exists only in this service's
    private RAM-backed mount) or, where that is unavailable, from key_path
    (mode 0400, owned by the service user).
  - The notifier never has plaintext. The store holds LXMF ciphertext; the
    daemon reads only the leading destination-hash bytes that lxmd itself
    uses to index the store.
  - A missed ping is a delayed message, never a lost one: lxmd holds the
    message until the app fetches it. This only buys latency.

TODO (before production)
  - Registration listener (memo section 08): accept {lxmf_hash, apns_token}
    bindings over RNS, authenticated by the registering identity, and write
    them to the token DB. Until then tokens.json is filled by hand.
  - Encrypted-envelope payload for the NSE (memo section 05). Today the push
    is content-free.
"""
import argparse
import configparser
import json
import os
import sys
import time
from pathlib import Path

DEFAULT_CONF = "/etc/analog/notifier.conf"
DEST_HASH_LEN = 16          # RNS.Identity.TRUNCATED_HASHLENGTH // 8
JWT_MAX_AGE = 50 * 60       # APNs wants provider tokens reused for 20–60 min
DORMANT_LOG_EVERY = 300

log = lambda *a: print("[analog-notifier]", *a, file=sys.stderr, flush=True)


# --- config -----------------------------------------------------------------

def load_config(path):
    cp = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
    if not Path(path).exists():
        return None
    cp.read(path)
    return cp


ENVS = ("production", "sandbox")
DEFAULT_HOST = {"production": "api.push.apple.com",
                "sandbox": "api.development.push.apple.com"}


def profile(cp, env):
    """The [apns.<env>] section ([apns] is accepted as production)."""
    if f"apns.{env}" in cp:
        return cp[f"apns.{env}"]
    if env == "production" and "apns" in cp:
        return cp["apns"]
    return None


def key_file(cp, env):
    """Where the .p8 for env is readable from, or None."""
    d = os.environ.get("CREDENTIALS_DIRECTORY")
    if d and Path(d, f"apns_p8_{env}").is_file():
        return Path(d, f"apns_p8_{env}")
    a = profile(cp, env)
    kp = a.get("key_path", "").strip() if a is not None else ""
    if kp and Path(kp).is_file():
        return Path(kp)
    return None


def missing_settings(cp, env):
    """What still blocks activation of env (empty when fully configured)."""
    if cp is None:
        return ["config file"]
    a = profile(cp, env)
    if a is None:
        return [f"[apns.{env}] section"]
    missing = [k for k in ("team_id", "key_id", "bundle_id")
               if a.get(k, "").strip() in ("", "REPLACE_ME")]
    if key_file(cp, env) is None:
        missing.append(f".p8 key (install.sh --install-key <file> --env {env})")
    return missing


def configured_envs(cp):
    return [e for e in ENVS if not missing_settings(cp, e)]


# --- token DB: {lxmf_destination_hash_hex: apns_device_token} ---------------

def load_tokens(cp):
    p = Path(cp["notifier"].get("token_db", "/var/lib/analog-notifier/tokens.json"))
    if not p.exists():
        return {}
    try:
        with p.open() as f:
            raw = json.load(f)
    except (OSError, ValueError) as e:
        log(f"token DB unreadable: {e}")
        return {}
    out = {}
    for k, v in raw.items():
        if isinstance(v, str):
            out[k.lower()] = (v, "production")
        elif isinstance(v, dict) and v.get("token"):
            out[k.lower()] = (v["token"], v.get("env", "production"))
    return out


# --- APNs -------------------------------------------------------------------

class Apns:
    """HTTP/2 client with a cached provider JWT, for one environment."""

    def __init__(self, cp, env):
        self.cp = cp
        self.env = env
        self._jwt = None
        self._jwt_at = 0.0
        self._client = None

    def _token(self):
        now = time.time()
        if self._jwt is None or now - self._jwt_at > JWT_MAX_AGE:
            import jwt
            a = profile(self.cp, self.env)
            key_bytes = key_file(self.cp, self.env).read_bytes()
            self._jwt = jwt.encode(
                {"iss": a["team_id"].strip(), "iat": int(now)},
                key_bytes, algorithm="ES256",
                headers={"kid": a["key_id"].strip()},
            )
            del key_bytes
            self._jwt_at = now
        return self._jwt

    def _http(self):
        if self._client is None:
            import httpx
            self._client = httpx.Client(http2=True, timeout=15)
        return self._client

    def send(self, device_token, recipient_hash):
        a = profile(self.cp, self.env)
        host = a.get("host", "").strip() or DEFAULT_HOST[self.env]
        # TODO (memo section 05): carry the E2E-encrypted envelope here.
        payload = {"aps": {"mutable-content": 1,
                           "alert": {"title": "Analog", "body": "New message"}}}
        headers = {
            "authorization": f"bearer {self._token()}",
            "apns-topic": a["bundle_id"].strip(),
            "apns-push-type": "alert",
            "apns-priority": "5",
        }
        try:
            r = self._http().post(f"https://{host}/3/device/{device_token}",
                                  json=payload, headers=headers)
        except Exception as e:  # network errors: log and move on
            log(f"APNs request failed for {recipient_hash[:8]}…: {e}")
            self._client = None
            return False
        if r.status_code == 200:
            log(f"APNs ping sent for {recipient_hash[:8]}… ({self.env})")
            return True
        log(f"APNs {r.status_code} for {recipient_hash[:8]}… ({self.env}): {r.text.strip()}")
        if r.status_code == 403:      # ExpiredProviderToken / InvalidProviderToken
            self._jwt = None
        return False


# --- notifier core ----------------------------------------------------------

class Notifier:
    def __init__(self, conf_path):
        self.conf_path = conf_path
        self.cp = None
        self.apns = {}             # env -> Apns
        self.conf_mtime = None
        self.last_ping = {}        # hash -> last ping time (coalescing)
        self.unknown = 0           # stored messages for recipients without a token
        self.last_summary = time.time()

    def reload(self):
        """Re-read the config when it changes on disk (no restart needed)."""
        try:
            mtime = os.stat(self.conf_path).st_mtime
        except OSError:
            mtime = None
        if self.cp is None or mtime != self.conf_mtime:
            self.cp = load_config(self.conf_path)
            self.conf_mtime = mtime
            self.apns = {}
            if self.cp is not None:
                for env in configured_envs(self.cp):
                    self.apns[env] = Apns(self.cp, env)
        return self.cp

    def ping(self, h):
        h = h.lower()
        window = int(self.cp["notifier"].get("coalesce_window_seconds", "60"))
        now = time.time()
        if now - self.last_ping.get(h, 0) < window:
            log(f"coalesced (within window) for {h[:8]}…")
            return
        entry = load_tokens(self.cp).get(h)
        if not entry:
            # Normal on a propagation node: most stored mail (incl. peer syncs)
            # is for recipients that never registered. Count, don't log each.
            self.unknown += 1
            return
        token, env = entry
        apns = self.apns.get(env)
        if apns is None:
            log(f"{h[:8]}… is registered for '{env}' but that environment is not "
                "configured — skipping")
            return
        self.last_ping[h] = now
        apns.send(token, h)
        # keep the coalesce map bounded
        if len(self.last_ping) > 10000:
            cutoff = now - window
            self.last_ping = {k: v for k, v in self.last_ping.items() if v >= cutoff}


def read_dest_hash(path):
    with open(path, "rb") as f:
        head = f.read(DEST_HASH_LEN)
    return head.hex() if len(head) == DEST_HASH_LEN else None


def daemon(conf_path):
    n = Notifier(conf_path)
    started = time.time()
    seen = set()
    last_dormant_log = 0.0
    while True:
        cp = n.reload()
        poll = 2.0
        if cp is not None:
            poll = float(cp["notifier"].get("poll_interval_seconds", "2"))
        if cp is None or not configured_envs(cp):
            if time.time() - last_dormant_log > DORMANT_LOG_EVERY:
                if cp is None:
                    log("dormant — config file missing")
                else:
                    for env in ENVS:
                        log(f"dormant — {env} missing: "
                            + ", ".join(missing_settings(cp, env)))
                last_dormant_log = time.time()
            time.sleep(max(poll, 5.0))
            continue
        if not n.apns:
            log("no environment configured; waiting")
            time.sleep(max(poll, 5.0))
            continue

        store = Path(cp["notifier"].get("messagestore", "").strip()
                     or "/var/lib/reticulum/.lxmd/storage/lxmf/messagestore")
        try:
            entries = list(os.scandir(store))
        except OSError as e:
            log(f"cannot read message store {store}: {e}")
            time.sleep(max(poll, 10.0))
            continue

        present = set()
        for e in entries:
            present.add(e.name)
            if e.name in seen or not e.is_file():
                continue
            try:
                st = e.stat()
                if st.st_mtime < started:      # backlog from before we started
                    seen.add(e.name)
                    continue
                if st.st_size < DEST_HASH_LEN:  # still being written
                    continue
                h = read_dest_hash(e.path)
            except OSError as err:
                log(f"skip {e.name}: {err}")
                continue
            seen.add(e.name)
            if h:
                n.ping(h)
        seen &= present
        if time.time() - n.last_summary > DORMANT_LOG_EVERY:
            if n.unknown:
                log(f"{n.unknown} stored message(s) for unregistered recipients "
                    f"in the last {DORMANT_LOG_EVERY // 60} min (normal on a propagation node)")
                n.unknown = 0
            n.last_summary = time.time()
        time.sleep(poll)


def trigger(conf_path, h):
    n = Notifier(conf_path)
    cp = n.reload()
    if not n.apns:
        for env in ENVS:
            log(f"{env} missing: " + ", ".join(missing_settings(cp, env)))
        return 1
    if not h:
        log("no recipient hash; nothing to ping")
        return 1
    n.ping(h)
    return 0


def main():
    ap = argparse.ArgumentParser(description="Analog APNs Notifier")
    ap.add_argument("--config", default=DEFAULT_CONF)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--daemon", action="store_true",
                   help="watch the lxmd message store and send wake-up pings")
    g.add_argument("--trigger", action="store_true",
                   help="send one ping for --recipient-hash (testing)")
    ap.add_argument("--recipient-hash", help="recipient LXMF destination hash (hex)")
    args = ap.parse_args()
    if args.daemon:
        daemon(args.config)
    sys.exit(trigger(args.config, args.recipient_hash))


if __name__ == "__main__":
    main()
PYEOF
    chmod 755 "${NOTIFIER_INSTALL_DIR}/analog_notifier.py"
    chown root:root "${NOTIFIER_INSTALL_DIR}/analog_notifier.py"
}

# Notifier config (placeholders). Caller sets: NOTIFIER_CONF_DIR, NOTIFIER_STATE_DIR,
# NOTIFIER_USER, NOTIFIER_GROUP, LXMD_STORE_DIR.
write_notifier_conf() {
    if [ -f "${NOTIFIER_CONF_DIR}/notifier.conf" ]; then
        log "Keeping existing ${NOTIFIER_CONF_DIR}/notifier.conf"
        # Migration: earlier versions pointed at .lxmd/storage/messagestore,
        # which lxmd never uses (the real store is under storage/lxmf/).
        if grep -q '^messagestore *= *.*/storage/messagestore *$' "${NOTIFIER_CONF_DIR}/notifier.conf"; then
            warn "Fixing messagestore path in notifier.conf -> ${LXMD_STORE_DIR}"
            sed -i "s|^messagestore *=.*|messagestore = ${LXMD_STORE_DIR}|" "${NOTIFIER_CONF_DIR}/notifier.conf"
        fi
    else
        log "Writing ${NOTIFIER_CONF_DIR}/notifier.conf"
        cat > "${NOTIFIER_CONF_DIR}/notifier.conf" <<EOF
# Analog APNs Notifier configuration.
#
# Activate with (once per environment you want to serve):
#   sudo sh install.sh --install-key AuthKey_<KEYID>.p8 --team-id <TEAMID> \\
#        --bundle-id app.analog.app --env production
#   sudo sh install.sh --install-key AuthKey_<KEYID>.p8 --team-id <TEAMID> \\
#        --bundle-id app.analog.dev --env sandbox
# That stores each key safely and fills the matching [apns.<env>] block.

[notifier]
# {lxmf_hash: apns_token} bindings.
token_db = ${NOTIFIER_STATE_DIR}/tokens.json
# One ping per recipient per this many seconds (burst -> single ping).
coalesce_window_seconds = 60
# lxmd propagation message store to watch (read-only, via ACL).
messagestore = ${LXMD_STORE_DIR}
poll_interval_seconds = 2

# One profile per APNs environment. A device token only works against the
# environment its build was signed for, so tokens.json records the env of
# every registration and the notifier picks the matching profile.
# key_path is the fallback location when systemd encrypted credentials are
# not available (Alpine, older systemd); ignored when the credential exists.

[apns.production]
team_id = REPLACE_ME
key_id = REPLACE_ME
bundle_id = REPLACE_ME
key_path = ${NOTIFIER_CONF_DIR}/apns_production.p8
host = api.push.apple.com

[apns.sandbox]
team_id = REPLACE_ME
key_id = REPLACE_ME
bundle_id = REPLACE_ME
key_path = ${NOTIFIER_CONF_DIR}/apns_sandbox.p8
host = api.development.push.apple.com
EOF
    fi
    chown "root:${NOTIFIER_GROUP}" "${NOTIFIER_CONF_DIR}/notifier.conf"
    chmod 640 "${NOTIFIER_CONF_DIR}/notifier.conf"

    # Empty token DB so the notifier has a valid file from the start.
    if [ ! -f "${NOTIFIER_STATE_DIR}/tokens.json" ]; then
        echo '{}' > "${NOTIFIER_STATE_DIR}/tokens.json"
    fi
    chown "${NOTIFIER_USER}:${NOTIFIER_GROUP}" "${NOTIFIER_STATE_DIR}/tokens.json"
    chmod 640 "${NOTIFIER_STATE_DIR}/tokens.json"
}

# lxmd config (propagation node). Caller sets: LXMD_CONFIG_FILE, RNS_USER, RNS_GROUP.
write_lxmd_config() {
    if [ -f "${LXMD_CONFIG_FILE}" ]; then
        BACKUP="${LXMD_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        log "Backing up existing lxmd config -> ${BACKUP}"
        cp -a "${LXMD_CONFIG_FILE}" "${BACKUP}"
    fi

    log "Writing lxmd config at ${LXMD_CONFIG_FILE}"
    cat > "${LXMD_CONFIG_FILE}" <<EOF
# lxmd configuration — Analog propagation node.
# Generated by install.sh.
# See: lxmd --exampleconfig
#
# The Analog notifier does NOT use on_inbound (that hook only fires for
# messages delivered to lxmd's own inbox). It watches storage/lxmf/messagestore
# read-only instead.

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

[logging]
  loglevel = 4
EOF
    chown "${RNS_USER}:${RNS_GROUP}" "${LXMD_CONFIG_FILE}"
    chmod 640 "${LXMD_CONFIG_FILE}"
}

# ============================================================================
# Service-definition writers (branch on INIT — the only place that emits
# systemd units or OpenRC init scripts).
# ============================================================================

# rnsd service. Caller sets: RNSD_BIN, RNS_*, SERVICE_NAME.
write_rnsd_service() {
    if [ "$INIT" = systemd ]; then
        UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        log "Writing systemd unit: ${UNIT_FILE}"
        cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=Reticulum Network Stack Daemon
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
# Uncomment if your network/WiFi needs extra time to come up:
# ExecStartPre=/bin/sleep 10
Type=simple
Restart=always
RestartSec=3
User=${RNS_USER}
Group=${RNS_GROUP}
UMask=0027
ExecStart=${RNSD_BIN} --service --config ${RNS_CONFIG_DIR}

# Logging — journald captures stdout/stderr by default
StandardOutput=journal
StandardError=journal

# Light sandboxing
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${RNS_HOME}

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "${UNIT_FILE}"
    else
        INIT_SCRIPT="/etc/init.d/${SERVICE_NAME}"
        log "Writing OpenRC init script: ${INIT_SCRIPT}"
        cat > "${INIT_SCRIPT}" <<EOF
#!/sbin/openrc-run
# Reticulum Network Stack Daemon

name="Reticulum Network Stack Daemon"
description="Runs the Reticulum Network Stack (rnsd) as a system service"

command="${RNSD_BIN}"
command_args="--service --config ${RNS_CONFIG_DIR}"
command_user="${RNS_USER}:${RNS_GROUP}"
umask=0027

supervisor="supervise-daemon"
# Auto-restart on crash, with a 3-second backoff (matches the
# systemd example in the Reticulum manual: Restart=always, RestartSec=3)
respawn_delay=3
respawn_max=0

output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.log"

depend() {
    need  net
    after firewall
}

start_pre() {
    checkpath -d -m 0750 -o ${RNS_USER}:${RNS_GROUP} "${RNS_HOME}"
    checkpath -d -m 0750 -o ${RNS_USER}:${RNS_GROUP} "${RNS_CONFIG_DIR}"
    checkpath -f -m 0640 -o ${RNS_USER}:${RNS_GROUP} "\${output_log}"
}
EOF
        chmod +x "${INIT_SCRIPT}"
    fi
}

# lxmd + analog-notifier services. Caller sets: LXMD_BIN, RNS_*, NOTIFIER_*.
write_notifier_services() {
    if [ "$INIT" = systemd ]; then
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
UMask=0027
ExecStart=${LXMD_BIN} --service --config ${LXMD_CONFIG_DIR} --rnsconfig ${RNS_CONFIG_DIR} --propagation-node

StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=${RNS_HOME}

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "${LXMD_UNIT}"

        NOTIFIER_UNIT="/etc/systemd/system/${NOTIFIER_NAME}.service"
        log "Writing systemd unit: ${NOTIFIER_UNIT}"
        cat > "${NOTIFIER_UNIT}" <<EOF
[Unit]
Description=Analog APNs Notifier (message-store watcher)
After=rnsd.service lxmd.service network-online.target
Wants=lxmd.service network-online.target
Requires=rnsd.service

[Service]
Type=simple
Restart=always
RestartSec=10
User=${NOTIFIER_USER}
Group=${NOTIFIER_GROUP}
UMask=0077
ExecStart=/usr/bin/env python3 ${NOTIFIER_INSTALL_DIR}/analog_notifier.py --config ${NOTIFIER_CONF_DIR}/notifier.conf --daemon
# The APNs key is delivered as an encrypted credential by the drop-in
# ${NOTIFIER_UNIT}.d/apns.conf, written by: install.sh --install-key

StandardOutput=journal
StandardError=journal

# Sandbox: this is the only process that can read the APNs key, so keep it
# small. Read-only filesystem except its own state/log dirs; no capabilities;
# no new privileges; only IP + unix sockets; service-level syscall filter.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=${NOTIFIER_STATE_DIR} ${NOTIFIER_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "${NOTIFIER_UNIT}"
        mkdir -p "${NOTIFIER_UNIT}.d"
    else
        LXMD_INIT="/etc/init.d/lxmd"
        log "Writing OpenRC init script: ${LXMD_INIT}"
        cat > "${LXMD_INIT}" <<EOF
#!/sbin/openrc-run
# LXMF Propagation Node Daemon (Analog)

name="LXMF Propagation Node (Analog)"
description="lxmd store-and-forward propagation node"

command="${LXMD_BIN}"
command_args="--service --config ${LXMD_CONFIG_DIR} --rnsconfig ${RNS_CONFIG_DIR} --propagation-node"
command_user="${RNS_USER}:${RNS_GROUP}"
umask=0027

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

        NOTIFIER_INIT="/etc/init.d/${NOTIFIER_NAME}"
        log "Writing OpenRC init script: ${NOTIFIER_INIT}"
        cat > "${NOTIFIER_INIT}" <<EOF
#!/sbin/openrc-run
# Analog APNs Notifier — message-store watcher

name="Analog APNs Notifier"
description="Watches the lxmd message store and sends APNs wake-up pings"

command="/usr/bin/env"
command_args="python3 ${NOTIFIER_INSTALL_DIR}/analog_notifier.py --config ${NOTIFIER_CONF_DIR}/notifier.conf --daemon"
command_user="${NOTIFIER_USER}:${NOTIFIER_GROUP}"
umask=0077

supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0

output_log="${NOTIFIER_LOG_DIR}/notifier.log"
error_log="${NOTIFIER_LOG_DIR}/notifier.log"

depend() {
    need rnsd net
    after lxmd firewall
}

start_pre() {
    checkpath -d -m 0750 -o ${NOTIFIER_USER}:${NOTIFIER_GROUP} "${NOTIFIER_LOG_DIR}"
    checkpath -f -m 0640 -o ${NOTIFIER_USER}:${NOTIFIER_GROUP} "\${output_log}"
}
EOF
        chmod +x "${NOTIFIER_INIT}"
    fi
}

# ============================================================================
# Small shared helpers used by both installers
# ============================================================================

# Create the reticulum service user/group + home + config dir.
create_service_user() {
    if ! getent group "${RNS_GROUP}" >/dev/null 2>&1; then
        log "Creating group '${RNS_GROUP}'"
        if [ "$PM" = apt ]; then addgroup --system "${RNS_GROUP}"
        else addgroup -S "${RNS_GROUP}"; fi
    fi
    if ! id -u "${RNS_USER}" >/dev/null 2>&1; then
        log "Creating system user '${RNS_USER}' with home ${RNS_HOME}"
        if [ "$PM" = apt ]; then
            adduser --system --group --no-create-home \
                    --home "${RNS_HOME}" --shell /usr/sbin/nologin \
                    --ingroup "${RNS_GROUP}" "${RNS_USER}" || \
            adduser --system --no-create-home \
                    --home "${RNS_HOME}" --shell /usr/sbin/nologin \
                    --ingroup "${RNS_GROUP}" "${RNS_USER}"
        else
            adduser -S -D -H -h "${RNS_HOME}" -s /sbin/nologin -G "${RNS_GROUP}" "${RNS_USER}"
        fi
    fi
    mkdir -p "${RNS_HOME}" "${RNS_CONFIG_DIR}"
    chown -R "${RNS_USER}:${RNS_GROUP}" "${RNS_HOME}"
    # Nothing under the service home is for "other": identities live here.
    chmod -R o-rwx "${RNS_HOME}"
    chmod 750 "${RNS_HOME}" "${RNS_CONFIG_DIR}"
}

# rnsd must already be installed before the notifier (shares user + RNS instance).
check_rnsd_present() {
    if [ ! -d "${RNS_CONFIG_DIR}" ]; then
        err "Reticulum config dir ${RNS_CONFIG_DIR} not found."
        err "Run the rnsd install first — the notifier shares the rnsd user and RNS instance."
        exit 1
    fi
    if ! id -u "${RNS_USER}" >/dev/null 2>&1; then
        err "Service user '${RNS_USER}' not found. Run the rnsd install first."
        exit 1
    fi
}

# Dedicated, unprivileged user for the notifier. Deliberately NOT a member of
# the reticulum group: the only thing it shares with rnsd/lxmd is a read-only
# ACL on the message-store directory (see grant_store_access).
create_notifier_user() {
    if ! getent group "${NOTIFIER_GROUP}" >/dev/null 2>&1; then
        log "Creating group '${NOTIFIER_GROUP}'"
        if [ "$PM" = apt ]; then addgroup --system "${NOTIFIER_GROUP}"
        else addgroup -S "${NOTIFIER_GROUP}"; fi
    fi
    if ! id -u "${NOTIFIER_USER}" >/dev/null 2>&1; then
        log "Creating system user '${NOTIFIER_USER}'"
        if [ "$PM" = apt ]; then
            adduser --system --no-create-home \
                    --home "${NOTIFIER_STATE_DIR}" --shell /usr/sbin/nologin \
                    --ingroup "${NOTIFIER_GROUP}" "${NOTIFIER_USER}"
        else
            adduser -S -D -H -h "${NOTIFIER_STATE_DIR}" -s /sbin/nologin \
                    -G "${NOTIFIER_GROUP}" "${NOTIFIER_USER}"
        fi
    fi
}

# Notifier directory layout + ownership.
#   code   : root-owned, world-readable (no secrets in it)
#   config : root:analog-notifier 750/640 (holds nothing secret except,
#            on non-systemd hosts, the 0400 key owned by the service user)
#   state  : analog-notifier-owned (token DB)
#   logs   : analog-notifier-owned
prepare_notifier_dirs() {
    log "Creating notifier directories..."
    mkdir -p "${NOTIFIER_INSTALL_DIR}" \
             "${NOTIFIER_CONF_DIR}" \
             "${NOTIFIER_STATE_DIR}" \
             "${NOTIFIER_LOG_DIR}" \
             "${LXMD_STORE_DIR}"

    chown root:root "${NOTIFIER_INSTALL_DIR}"
    chmod 755 "${NOTIFIER_INSTALL_DIR}"

    chown "root:${NOTIFIER_GROUP}" "${NOTIFIER_CONF_DIR}"
    chmod 750 "${NOTIFIER_CONF_DIR}"

    chown "${NOTIFIER_USER}:${NOTIFIER_GROUP}" "${NOTIFIER_STATE_DIR}" "${NOTIFIER_LOG_DIR}"
    chmod 750 "${NOTIFIER_STATE_DIR}" "${NOTIFIER_LOG_DIR}"

    # lxmd's tree stays with the reticulum user. Creating the store ahead of
    # lxmd's first start lets us attach the ACL before any message lands.
    chown -R "${RNS_USER}:${RNS_GROUP}" "${LXMD_CONFIG_DIR}"
    chmod 750 "${LXMD_CONFIG_DIR}"

    # Strip "other" access from the whole reticulum home: the rnsd and lxmd
    # identities are in here and must not be readable by the notifier user
    # (or anyone else). The ACL below is the only way in for the notifier.
    chmod -R o-rwx "${RNS_HOME}"
}

# Give the notifier user read-only access to lxmd's message store — and only
# that. Traverse-only (x) on the parent dirs means it cannot list or read
# rnsd's / lxmd's identities or configs; r on the store lets it read the
# 16-byte destination-hash header of each stored message.
grant_store_access() {
    command -v setfacl >/dev/null 2>&1 || { err "setfacl not found (package 'acl'); cannot grant store access."; exit 1; }
    log "Granting ${NOTIFIER_USER} read-only ACL on ${LXMD_STORE_DIR}"
    setfacl -m "u:${NOTIFIER_USER}:x"  "${RNS_HOME}" "${LXMD_CONFIG_DIR}" "${LXMD_CONFIG_DIR}/storage" "${LXMD_CONFIG_DIR}/storage/lxmf"
    setfacl -m "u:${NOTIFIER_USER}:rx" "${LXMD_STORE_DIR}"
    setfacl -d -m "u:${NOTIFIER_USER}:r" "${LXMD_STORE_DIR}"
    find "${LXMD_STORE_DIR}" -type f -exec setfacl -m "u:${NOTIFIER_USER}:r" {} +
}

# Best-effort install of native Python deps; installs a build toolchain if any
# are missing so pip can compile them. Args: core-deps, native-deps, build-deps.
install_native_python_deps() {
    # shellcheck disable=SC2086
    pkg_install $1
    log "Installing native Python deps (best-effort — pip fills any gaps)..."
    need_build_tools=0
    # shellcheck disable=SC2086
    for pkg in $2; do
        if pkg_install_quiet "${pkg}"; then
            log "  installed ${pkg}"
        else
            warn "  ${pkg} not available via ${PM} — pip will build it from source"
            need_build_tools=1
        fi
    done
    if [ "${need_build_tools}" -eq 1 ]; then
        log "Installing build toolchain so pip can compile missing deps..."
        # shellcheck disable=SC2086
        pkg_install $3
    fi
}

# ============================================================================
# rnsd installer  (6 phases, single code path, branched on PM/INIT)
# ============================================================================

install_rnsd() {
    log "==> Installing rnsd (${PM} / ${INIT})"
    PHASE_NUM=0
    PHASE_TOTAL=6

    if [ "$PM" = apt ]; then
        CORE_DEPS="ca-certificates python3 python3-pip python3-full adduser"
        NATIVE_DEPS="python3-cryptography python3-netifaces python3-serial"
        BUILD_DEPS="build-essential python3-dev libffi-dev libssl-dev cargo rustc pkg-config"
    else
        CORE_DEPS="python3 py3-pip shadow openrc"
        NATIVE_DEPS="py3-cryptography py3-netifaces py3-pyserial"
        BUILD_DEPS="gcc musl-dev python3-dev libffi-dev openssl-dev cargo rust make pkgconf"
    fi

    # ── PREFLIGHT ──────────────────────────────────────────────────────────
    if [ "$PM" = apt ]; then
        command -v apt-get >/dev/null 2>&1 || { err "apt-get not found. This environment is not Debian/Ubuntu."; exit 1; }
        command -v systemctl >/dev/null 2>&1 || { err "systemctl not found. This requires a systemd-based system."; exit 1; }
        export DEBIAN_FRONTEND=noninteractive
    else
        [ -f /etc/alpine-release ] || warn "This does not look like Alpine Linux. Continuing anyway..."
        command -v rc-update >/dev/null 2>&1 || { err "OpenRC (rc-update) not found. This requires Alpine/OpenRC."; exit 1; }
    fi

    # ═══ PHASE 1 — System dependencies ═════════════════════════════════════
    phase "System dependencies"
    log "Updating ${PM} index and installing system dependencies..."
    pkg_update
    install_native_python_deps "${CORE_DEPS}" "${NATIVE_DEPS}" "${BUILD_DEPS}"

    # ═══ PHASE 2 — Service user ════════════════════════════════════════════
    phase "Service user"
    create_service_user

    # ═══ PHASE 3 — Install rns + lxmf via pip ══════════════════════════════
    phase "Install rns + lxmf via pip"
    log "Installing/upgrading Reticulum (rns) and LXMF via pip..."
    pip_install rns lxmf
    RNSD_BIN="$(find_bin rnsd)"
    [ -n "${RNSD_BIN}" ] || { err "rnsd binary not found on PATH after installation."; exit 1; }
    log "rnsd installed at ${RNSD_BIN}"

    # ═══ PHASE 4 — Write RNS config (stop existing first) ══════════════════
    phase "Write RNS config (stop existing first)"
    if svc_is_active "${SERVICE_NAME}"; then
        log "Stopping existing ${SERVICE_NAME} before reconfiguring..."
        svc_stop "${SERVICE_NAME}"
    fi
    CONFIG_FILE="${RNS_CONFIG_DIR}/config"
    HOSTNAME_SLUG="$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
    if [ -f "${CONFIG_FILE}" ]; then
        BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        log "Backing up existing config -> ${BACKUP}"
        cp -a "${CONFIG_FILE}" "${BACKUP}"
    fi
    write_rns_config

    # ═══ PHASE 5 — Write service definition ════════════════════════════════
    phase "Write service definition (${INIT})"
    write_rnsd_service

    # ═══ PHASE 6 — Enable + start + verify ═════════════════════════════════
    phase "Enable + start + verify"
    svc_reload
    svc_enable "${SERVICE_NAME}"
    svc_restart_or_start "${SERVICE_NAME}"
    sleep 2
    svc_status "${SERVICE_NAME}" || true

    # Banner — only the service/log/command wording differs by init system.
    if [ "$INIT" = systemd ]; then
        n_svc_name="${SERVICE_NAME}.service"
        n_log_line="Logs         : journalctl -u ${SERVICE_NAME} -f"
        n_cmd_status="systemctl status ${SERVICE_NAME}"
        n_cmd_restart="systemctl restart ${SERVICE_NAME}"
        n_cmd_stop="systemctl stop ${SERVICE_NAME}"
        n_cmd_logs="journalctl -u ${SERVICE_NAME} -f"
        n_restart_cmd="systemctl restart ${SERVICE_NAME}"
        n_fw_hint="e.g. ufw allow 4242/tcp"
    else
        n_svc_name="${SERVICE_NAME}"
        n_log_line="Log file     : /var/log/${SERVICE_NAME}.log"
        n_cmd_status="rc-service ${SERVICE_NAME} status"
        n_cmd_restart="rc-service ${SERVICE_NAME} restart"
        n_cmd_stop="rc-service ${SERVICE_NAME} stop"
        n_cmd_logs="tail -f /var/log/${SERVICE_NAME}.log"
        n_restart_cmd="rc-service ${SERVICE_NAME} restart"
        n_fw_hint="awall/iptables/nftables"
    fi
    cat <<EOF

------------------------------------------------------------
 Reticulum has been installed and is running as a service.

   Service name : ${n_svc_name}
   Run as user  : ${RNS_USER}
   Config file  : ${CONFIG_FILE}
   ${n_log_line}

 Useful commands:
   ${n_cmd_status}
   ${n_cmd_restart}
   ${n_cmd_stop}
   ${n_cmd_logs}

 Edit the config, then restart the service:
   \$EDITOR ${CONFIG_FILE}
   ${n_restart_cmd}

 Configured interfaces:
   - AutoInterface        (LAN auto-discovery, link-local IPv6)
   - TCPServerInterface   (listening on 0.0.0.0:4242)
   - 5x TCPClientInterface  (Beleth, Ether Whisperer, Catz, RMAP, US-East)
   - 2x BackboneInterface   (bnZ-NODE01 Gothenburg, Pleiades Inc.)

 If you have a firewall, allow inbound TCP 4242 so peers can reach your
 TCPServerInterface (${n_fw_hint}).
------------------------------------------------------------
EOF

    echo "alias rnstatus='rnstatus --config /var/lib/reticulum/.reticulum'" >> ~/.bashrc
    # shellcheck disable=SC1090,SC1091
    . ~/.bashrc 2>/dev/null || true
}

# ============================================================================
# Analog notifier installer  (6 phases, single code path, branched on PM/INIT;
# depends on rnsd already being installed — checked in PREFLIGHT)
# ============================================================================

install_notifier() {
    log "==> Installing Analog notifier (${PM} / ${INIT})"
    PHASE_NUM=0
    PHASE_TOTAL=6

    if [ "$PM" = apt ]; then
        CORE_DEPS="ca-certificates python3 python3-pip acl adduser"
    else
        CORE_DEPS="python3 py3-pip acl shadow"
    fi

    # ── PREFLIGHT ──────────────────────────────────────────────────────────
    check_rnsd_present
    if [ "$PM" = apt ]; then
        command -v apt-get >/dev/null 2>&1 || { err "apt-get not found. This environment is not Debian/Ubuntu."; exit 1; }
        command -v systemctl >/dev/null 2>&1 || { err "systemctl not found. This requires a systemd-based system."; exit 1; }
        export DEBIAN_FRONTEND=noninteractive
    else
        [ -f /etc/alpine-release ] || warn "This does not look like Alpine Linux. Continuing anyway..."
        command -v rc-update >/dev/null 2>&1 || { err "OpenRC (rc-update) not found. This requires Alpine/OpenRC."; exit 1; }
    fi

    # ═══ PHASE 1 — System + Python dependencies ═══════════════════════════
    phase "System + Python dependencies"
    log "Updating ${PM} index and installing system dependencies..."
    pkg_update
    # shellcheck disable=SC2086
    pkg_install ${CORE_DEPS}

    log "Ensuring lxmf (provides lxmd) is installed..."
    pip_install lxmf
    LXMD_BIN="$(find_bin lxmd)"
    [ -n "${LXMD_BIN}" ] || { err "lxmd binary not found after installing lxmf."; exit 1; }
    log "lxmd installed at ${LXMD_BIN}"

    log "Installing notifier Python deps (jwt, httpx, h2, cryptography)..."
    if [ "$PM" = apt ]; then
        ensure_py_modules jwt:python3-jwt:PyJWT httpx:python3-httpx:httpx \
                          h2:python3-h2:h2 cryptography:python3-cryptography:cryptography
    else
        ensure_py_modules jwt:py3-jwt:PyJWT httpx:py3-httpx:httpx \
                          h2:py3-h2:h2 cryptography:py3-cryptography:cryptography
    fi

    # ═══ PHASE 2 — Service user + directory layout ═════════════════════════
    phase "Service user + directory layout"
    create_notifier_user
    prepare_notifier_dirs
    grant_store_access

    # ═══ PHASE 3 — Write notifier code + config ════════════════════════════
    phase "Write notifier code + config"
    write_notifier_python
    write_notifier_conf
    # Remove the legacy on_inbound shim if a previous version installed it.
    rm -f "${NOTIFIER_INSTALL_DIR}/on_inbound_trigger.sh"

    # ═══ PHASE 4 — Write lxmd config ═══════════════════════════════════════
    phase "Write lxmd config"
    LXMD_CONFIG_FILE="${LXMD_CONFIG_DIR}/config"
    write_lxmd_config

    # ═══ PHASE 5 — Write service definitions (lxmd + notifier) ═════════════
    phase "Write service definitions (lxmd + notifier)"
    write_notifier_services
    # rnsd installed by an older script has no UMask → its ratchets/identities
    # are created world-readable. Add a drop-in and restart it (a few seconds;
    # lxmd reconnects to the shared instance by itself).
    if [ "$INIT" = systemd ] && [ -f /etc/systemd/system/rnsd.service ] \
       && ! grep -q '^UMask=' /etc/systemd/system/rnsd.service \
       && [ ! -f /etc/systemd/system/rnsd.service.d/umask.conf ]; then
        log "Adding UMask=0027 drop-in to rnsd.service and restarting rnsd"
        mkdir -p /etc/systemd/system/rnsd.service.d
        printf '[Service]\nUMask=0027\n' > /etc/systemd/system/rnsd.service.d/umask.conf
        systemctl daemon-reload
        systemctl restart rnsd.service || warn "rnsd restart failed — check: journalctl -u rnsd -n 20"
        chmod -R o-rwx "${RNS_HOME}"
    fi

    # ═══ PHASE 6 — Enable + start + verify ═════════════════════════════════
    phase "Enable + start + verify"
    svc_reload
    svc_enable lxmd
    svc_enable "${NOTIFIER_NAME}"

    if svc_is_active rnsd; then
        log "Starting lxmd..."
        svc_restart lxmd || svc_start lxmd
    else
        if [ "$INIT" = systemd ]; then
            warn "rnsd is not active — start it first, then: systemctl start lxmd ${NOTIFIER_NAME}"
        else
            warn "rnsd is not running — start it first, then: rc-service lxmd start; rc-service ${NOTIFIER_NAME} start"
        fi
    fi

    log "Starting ${NOTIFIER_NAME} (dormant until the APNs key is installed)..."
    svc_restart "${NOTIFIER_NAME}" || svc_start "${NOTIFIER_NAME}" || true

    sleep 2
    svc_status lxmd || true
    svc_status "${NOTIFIER_NAME}" || true

    # Banner — only service/log/command wording differs by init system.
    if [ "$INIT" = systemd ]; then
        n_lxmd_svc="lxmd.service"
        n_noti_svc="${NOTIFIER_NAME}.service"
        n_logs_l1="tail -f ${LXMD_CONFIG_DIR}/logfile   (lxmd --service logs to a file, not the journal)"
        n_logs_l2="journalctl -u ${NOTIFIER_NAME} -f"
        n_key_store="systemd encrypted credential (${NOTIFIER_CONF_DIR}/apns_p8_<env>.cred), decrypted only inside ${NOTIFIER_NAME}.service"
    else
        n_lxmd_svc="rc-service lxmd <status|restart|stop>"
        n_noti_svc="rc-service ${NOTIFIER_NAME} <status|restart|stop>"
        n_logs_l1="tail -f /var/log/lxmd.log"
        n_logs_l2="tail -f ${NOTIFIER_LOG_DIR}/notifier.log"
        n_key_store="${NOTIFIER_CONF_DIR}/apns_<env>.p8, mode 0400, owned by ${NOTIFIER_USER}"
    fi
    cat <<EOF

------------------------------------------------------------
 Analog notifier stack installed alongside rnsd.

   lxmd service          : ${n_lxmd_svc}
   notifier service      : ${n_noti_svc}   (user: ${NOTIFIER_USER})
   notifier script       : ${NOTIFIER_INSTALL_DIR}/analog_notifier.py
   notifier config       : ${NOTIFIER_CONF_DIR}/notifier.conf
   token DB              : ${NOTIFIER_STATE_DIR}/tokens.json
   watched store         : ${LXMD_STORE_DIR}  (read-only ACL)
   lxmd config           : ${LXMD_CONFIG_FILE}
   logs                  : ${n_logs_l1}
                            ${n_logs_l2}
   node status           : sudo -u ${RNS_USER} lxmd --status --config ${LXMD_CONFIG_DIR} --rnsconfig ${RNS_CONFIG_DIR}

 NEXT STEP — install the APNs key(s). The notifier is dormant until at
 least one environment is configured; configure both to serve production
 (app.analog.app) and development (app.analog.dev) builds from one node.

   1. Apple Developer > Keys > APNs Auth Key: download AuthKey_<KEYID>.p8,
      note your Team ID.
   2. Copy it to this host over SSH (scp), then run from a local copy of
      this script:

        sudo sh install.sh --install-key /path/to/AuthKey_<KEYID>.p8 \\
             --team-id <TEAMID> --bundle-id app.analog.app --env production
        sudo sh install.sh --install-key /path/to/AuthKey_<KEYID>.p8 \\
             --team-id <TEAMID> --bundle-id app.analog.dev --env sandbox

   Keys are stored as: ${n_key_store}
   rnsd and lxmd cannot read them. Afterwards shred the uploaded copies.

 STILL TODO (skeleton): registration listener over RNS (memo §08) — until
 then add entries to tokens.json by hand:
     "<lxmf_hash>": "<apns_token>"                            (production)
     "<lxmf_hash>": {"token": "<apns_token>", "env": "sandbox"}
 encrypted-envelope payload (memo §05).

 The propagation node (lxmd) is live now and holds offline mail regardless
 of the notifier — that part does not depend on APNs being configured.
------------------------------------------------------------
EOF
}

# ============================================================================
# APNs key installation  (install.sh --install-key FILE ...)
# ============================================================================

usage_install_key() {
    cat <<EOF
Usage: install.sh --install-key FILE --env production|sandbox
                  [--team-id ID] [--key-id ID] [--bundle-id ID]

  FILE          the AuthKey_<KEYID>.p8 downloaded from Apple Developer
  --env         which APNs environment this key/bundle serves:
                  production  -> app.analog.app, api.push.apple.com
                  sandbox     -> app.analog.dev, api.development.push.apple.com
                (derived from --bundle-id when omitted: *.dev -> sandbox)
  --team-id     Apple Team ID (10 chars)
  --key-id      APNs Key ID; derived from the file name when omitted
  --bundle-id   app.analog.app or app.analog.dev

Run once per environment. Each key is stored so that only the
${NOTIFIER_NAME} service can read it; the matching [apns.<env>] block in
${NOTIFIER_CONF_DIR}/notifier.conf is filled and the service restarted.
EOF
}

# conf_set SECTION KEY VALUE — set "KEY = VALUE" inside [SECTION] of notifier.conf.
conf_set() {
    _f="${NOTIFIER_CONF_DIR}/notifier.conf"
    awk -v sec="[$1]" -v key="$2" -v val="$3" '
        /^\[/ { insec = ($0 == sec) }
        insec && $1 == key && $2 == "=" { print key " = " val; next }
        { print }
    ' "${_f}" > "${_f}.tmp.$$" && cat "${_f}.tmp.$$" > "${_f}" && rm -f "${_f}.tmp.$$"
}

# conf_get SECTION KEY — echo the value.
conf_get() {
    awk -v sec="[$1]" -v key="$2" '
        /^\[/ { insec = ($0 == sec) }
        insec && $1 == key && $2 == "=" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
    ' "${NOTIFIER_CONF_DIR}/notifier.conf"
}

install_apns_key() {
    KEY_SRC=""; TEAM_ID=""; KEY_ID=""; BUNDLE_ID=""; APNS_ENV=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --install-key) KEY_SRC="$2"; shift 2 ;;
            --team-id)     TEAM_ID="$2"; shift 2 ;;
            --key-id)      KEY_ID="$2"; shift 2 ;;
            --bundle-id)   BUNDLE_ID="$2"; shift 2 ;;
            --env)         APNS_ENV="$2"; shift 2 ;;
            --sandbox)     APNS_ENV="sandbox"; shift ;;
            --production)  APNS_ENV="production"; shift ;;
            -h|--help)     usage_install_key; exit 0 ;;
            *) err "Unknown option: $1"; usage_install_key; exit 1 ;;
        esac
    done
    [ -n "${KEY_SRC}" ] || { usage_install_key; exit 1; }
    [ -f "${KEY_SRC}" ] || { err "Key file not found: ${KEY_SRC}"; exit 1; }
    grep -q 'PRIVATE KEY' "${KEY_SRC}" || { err "${KEY_SRC} does not look like a PEM .p8 key."; exit 1; }

    if [ -z "${APNS_ENV}" ]; then
        case "${BUNDLE_ID}" in
            *.dev) APNS_ENV=sandbox ;;
            "")    err "--env production|sandbox is required (or pass --bundle-id)"; exit 1 ;;
            *)     APNS_ENV=production ;;
        esac
    fi
    case "${APNS_ENV}" in
        production) APNS_HOST="api.push.apple.com" ;;
        sandbox)    APNS_HOST="api.development.push.apple.com" ;;
        *) err "--env must be production or sandbox (got '${APNS_ENV}')"; exit 1 ;;
    esac
    SECTION="apns.${APNS_ENV}"
    CRED_FILE="${NOTIFIER_CONF_DIR}/apns_p8_${APNS_ENV}.cred"
    KEY_FILE="${NOTIFIER_CONF_DIR}/apns_${APNS_ENV}.p8"
    CRED_NAME="apns_p8_${APNS_ENV}"

    # Environment: honour RNS_ENV, else auto-detect (no prompt).
    case "${RNS_ENV:-}" in
        apt) ENV_CHOICE=apt ;;
        apk) ENV_CHOICE=apk ;;
        *)   if [ "$(detect_default_env)" = 2 ]; then ENV_CHOICE=apk; else ENV_CHOICE=apt; fi ;;
    esac
    resolve_os_switches

    [ -f "${NOTIFIER_CONF_DIR}/notifier.conf" ] && id -u "${NOTIFIER_USER}" >/dev/null 2>&1 || {
        err "Notifier is not installed (missing ${NOTIFIER_CONF_DIR}/notifier.conf or user ${NOTIFIER_USER})."
        err "Run the installer first: sudo sh install.sh"
        exit 1
    }
    grep -q "^\[${SECTION}\]" "${NOTIFIER_CONF_DIR}/notifier.conf" || {
        err "[${SECTION}] section not found in notifier.conf — move the old file aside and re-run the installer to regenerate it."
        exit 1
    }

    # Key ID from AuthKey_<KEYID>.p8 unless given.
    if [ -z "${KEY_ID}" ]; then
        KEY_ID="$(basename "${KEY_SRC}" | sed -n 's/^AuthKey_\([A-Za-z0-9]*\)\.p8$/\1/p')"
        [ -n "${KEY_ID}" ] || warn "Could not derive the Key ID from the file name — pass --key-id"
    fi

    # --- Store the key --------------------------------------------------------
    STORED_AS=""
    DROPIN_DIR="/etc/systemd/system/${NOTIFIER_NAME}.service.d"
    if [ "$INIT" = systemd ] && command -v systemd-creds >/dev/null 2>&1; then
        log "Encrypting the ${APNS_ENV} key as a systemd credential (host-bound) ..."
        TMP_CRED="${CRED_FILE}.tmp.$$"
        if systemd-creds encrypt --name="${CRED_NAME}" "${KEY_SRC}" "${TMP_CRED}" 2>/dev/null; then
            chmod 600 "${TMP_CRED}"
            chown root:root "${TMP_CRED}"
            mv -f "${TMP_CRED}" "${CRED_FILE}"
            mkdir -p "${DROPIN_DIR}"
            cat > "${DROPIN_DIR}/apns-${APNS_ENV}.conf" <<EOF
# Written by install.sh --install-key --env ${APNS_ENV}. The .p8 is decrypted
# by systemd into this service's private credentials directory only.
[Service]
LoadCredentialEncrypted=${CRED_NAME}:${CRED_FILE}
EOF
            # Never leave a plaintext copy next to the encrypted one.
            [ -f "${KEY_FILE}" ] && { shred -u "${KEY_FILE}" 2>/dev/null || rm -f "${KEY_FILE}"; }
            STORED_AS="encrypted credential ${CRED_FILE} (root-only; decrypted only inside ${NOTIFIER_NAME}.service)"
        else
            rm -f "${TMP_CRED}"
            warn "systemd-creds encrypt failed (systemd < 250 or no host key) — falling back to a 0400 file"
        fi
    fi
    if [ -z "${STORED_AS}" ]; then
        log "Storing the ${APNS_ENV} key at ${KEY_FILE} (0400, owned by ${NOTIFIER_USER})"
        # Copy, then lock down — never let a readable intermediate exist.
        ( umask 077 && cp "${KEY_SRC}" "${KEY_FILE}.tmp.$$" )
        chown "${NOTIFIER_USER}:${NOTIFIER_GROUP}" "${KEY_FILE}.tmp.$$"
        chmod 0400 "${KEY_FILE}.tmp.$$"
        mv -f "${KEY_FILE}.tmp.$$" "${KEY_FILE}"
        rm -f "${DROPIN_DIR}/apns-${APNS_ENV}.conf" 2>/dev/null || true
        STORED_AS="${KEY_FILE} (mode 0400, owner ${NOTIFIER_USER})"
    fi

    # --- Fill the config ------------------------------------------------------
    log "Updating [${SECTION}] in ${NOTIFIER_CONF_DIR}/notifier.conf"
    conf_set "${SECTION}" key_path "${KEY_FILE}"
    conf_set "${SECTION}" host     "${APNS_HOST}"
    [ -n "${KEY_ID}" ]    && conf_set "${SECTION}" key_id    "${KEY_ID}"
    [ -n "${TEAM_ID}" ]   && conf_set "${SECTION}" team_id   "${TEAM_ID}"
    [ -n "${BUNDLE_ID}" ] && conf_set "${SECTION}" bundle_id "${BUNDLE_ID}"
    chown "root:${NOTIFIER_GROUP}" "${NOTIFIER_CONF_DIR}/notifier.conf"
    chmod 640 "${NOTIFIER_CONF_DIR}/notifier.conf"

    svc_reload
    svc_restart "${NOTIFIER_NAME}" || svc_start "${NOTIFIER_NAME}" || true
    sleep 2
    svc_status "${NOTIFIER_NAME}" || true

    still_missing=""
    for k in team_id key_id bundle_id; do
        v="$(conf_get "${SECTION}" "$k")"
        if [ -z "$v" ] || [ "$v" = REPLACE_ME ]; then
            still_missing="${still_missing} --$(echo "$k" | tr _ -)"
        fi
    done

    cat <<EOF

------------------------------------------------------------
 APNs key installed for environment: ${APNS_ENV}

   stored as : ${STORED_AS}
   readable  : only by ${NOTIFIER_NAME} (rnsd/lxmd cannot read it)
   profile   : [${SECTION}]  bundle_id=$(conf_get "${SECTION}" bundle_id)  host=${APNS_HOST}
   config    : ${NOTIFIER_CONF_DIR}/notifier.conf
EOF
    if [ -n "${still_missing}" ]; then
        printf '\n   Still REPLACE_ME in [%s]:%s\n   Re-run --install-key --env %s with those flags, or edit the file.\n' \
            "${SECTION}" "${still_missing}" "${APNS_ENV}"
    fi
    if [ "${APNS_ENV}" = production ]; then other_env=sandbox; other_bundle=app.analog.dev
    else other_env=production; other_bundle=app.analog.app; fi
    if [ "$(conf_get "apns.${other_env}" team_id)" = REPLACE_ME ]; then
        printf '\n   The %s environment is not configured yet. To serve those builds too:\n' "${other_env}"
        printf '     sudo sh install.sh --install-key <AuthKey.p8> --team-id <ID> --env %s --bundle-id %s\n' \
            "${other_env}" "${other_bundle}"
    fi
    cat <<EOF

 Now remove the uploaded copy so the only key on this host is the protected one:

     shred -u "${KEY_SRC}"      # Alpine/busybox has no shred: rm -f "${KEY_SRC}"

 Keep the .p8 backed up OFF this host (password manager / offline). Apple
 does not let you re-download a key: a lost key means creating a new one.
------------------------------------------------------------
EOF
}

# ============================================================================
# Interactive prompts
# ============================================================================

# Read one line from the terminal. Under `curl | sh` stdin is the script
# itself, so read from /dev/tty; if no tty is available, return empty so the
# caller falls back to the default.
read_tty() {
    REPLY=""
    if [ -r /dev/tty ]; then
        read REPLY < /dev/tty || true
    else
        warn "No terminal available — using default"
    fi
}

# Echo "1" for apt default, "2" for apk default, based on what's detected.
detect_default_env() {
    if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
        echo 2
    elif command -v apt-get >/dev/null 2>&1; then
        echo 1
    elif [ -f /etc/alpine-release ]; then
        echo 2
    else
        echo 1
    fi
}

prompt_env() {
    # Allow non-interactive override.
    case "${RNS_ENV:-}" in
        apt) ENV_CHOICE=apt; log "RNS_ENV=apt — skipping environment prompt"; return ;;
        apk) ENV_CHOICE=apk; log "RNS_ENV=apk — skipping environment prompt"; return ;;
    esac

    default="$(detect_default_env)"
    apt_marker=""
    apk_marker=""
    [ "${default}" = "1" ] && apt_marker="   [detected]"
    [ "${default}" = "2" ] && apk_marker="   [detected]"

    printf '\n\033[1mSelect the environment:\033[0m\n'
    printf '  1) APT (Debian/Ubuntu, systemd)%s\n' "${apt_marker}"
    printf '  2) APK (Alpine, OpenRC)%s\n' "${apk_marker}"
    printf 'Enter choice [%s]: ' "${default}"
    read_tty
    case "${REPLY:-${default}}" in
        1|apt|APT) ENV_CHOICE=apt ;;
        2|apk|APK) ENV_CHOICE=apk ;;
        *) err "Invalid selection: '${REPLY}'"; exit 1 ;;
    esac
}

# Is rnsd already installed on this system? (config dir + service user present)
rnsd_installed() {
    [ -d "${RNS_CONFIG_DIR}" ] && id -u "${RNS_USER}" >/dev/null 2>&1
}

prompt_install() {
    # Non-interactive override.
    case "${RNS_INSTALL:-}" in
        full)     INSTALL_MODE=full;     log "RNS_INSTALL=full — skipping install prompt"; return ;;
        rnsd)     INSTALL_MODE=rnsd;     log "RNS_INSTALL=rnsd — skipping install prompt"; return ;;
        notifier) INSTALL_MODE=notifier; log "RNS_INSTALL=notifier — skipping install prompt"; return ;;
    esac
    # Legacy alias: RNS_NOTIFIER=yes|no  (yes→full, no→rnsd).
    case "${RNS_NOTIFIER:-}" in
        yes|Yes|YES|1) INSTALL_MODE=full; log "RNS_NOTIFIER=yes (→ full) — skipping install prompt"; return ;;
        no|No|NO|0)    INSTALL_MODE=rnsd; log "RNS_NOTIFIER=no (→ rnsd) — skipping install prompt"; return ;;
    esac

    # Default to "notifier only" when rnsd is already installed, else "full".
    if rnsd_installed; then
        default=3
        opt3_hint="   [rnsd detected]"
    else
        default=1
        opt3_hint="   (rnsd not yet installed here)"
    fi

    printf '\n\033[1mSelect what to install:\033[0m\n'
    printf '  1) rnsd + Analog notifier   (full stack)\n'
    printf '  2) rnsd only\n'
    printf '  3) Analog notifier only    (requires rnsd already installed)%s\n' "${opt3_hint}"
    printf 'Enter choice [%s]: ' "${default}"
    read_tty
    case "${REPLY:-${default}}" in
        1) INSTALL_MODE=full ;;
        2) INSTALL_MODE=rnsd ;;
        3) INSTALL_MODE=notifier ;;
        *) err "Invalid selection: '${REPLY}'"; exit 1 ;;
    esac
}

# Resolve the PM/INIT switches from the environment choice.
# (PIP_FLAGS is resolved lazily by pip_install, after python3 is installed.)
resolve_os_switches() {
    if [ "${ENV_CHOICE}" = apt ]; then
        PM=apt
        INIT=systemd
    else
        PM=apk
        INIT=openrc
    fi
}

# ============================================================================
# main
# ============================================================================

# All work happens inside main() and main is only invoked on the final line.
# If this script is truncated mid-download (curl | sh / wget | sh), the shell
# fails to parse an incomplete function body before main is ever called, so
# nothing partial executes.
main() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root (try: sudo $0)"
        exit 1
    fi

    case "${1:-}" in
        --install-key) install_apns_key "$@"; exit 0 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
            usage_install_key
            exit 0 ;;
    esac

    printf '\033[1mReticulum + Analog notifier installer\033[0m\n'
    printf '  rnsd        : Reticulum Network Stack daemon\n'
    printf '  notifier    : lxmd (LXMF propagation node) + analog-notifier (APNs wake-up, skeleton)\n'


    prompt_env
    prompt_install
    resolve_os_switches

    printf '\n'
    case "${INSTALL_MODE}" in
        full)
            install_rnsd
            printf '\n'
            install_notifier
            ;;
        rnsd)
            install_rnsd
            ;;
        notifier)
            install_notifier
            ;;
    esac
}

main "$@"