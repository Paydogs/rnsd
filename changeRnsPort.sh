#!/bin/sh
#
# changeRnsPort.sh — change the port of rnsd's TCPServerInterface on a
# running server installed by install.sh / installRnsd_*.sh.
#
# Asks for the new port (or takes it as $1), then:
#   1. checks nothing else is listening on it
#   2. rewrites listen_port in the RNS config (backup kept)
#   3. restarts rnsd (systemd or OpenRC) and verifies the listener
#   4. updates a ufw rule if ufw is active
#
# Usage:  sudo ./changeRnsPort.sh [PORT]
#

set -eu

RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-/var/lib/reticulum/.reticulum}"
CONFIG_FILE="${RNS_CONFIG_DIR}/config"
SERVICE_NAME="rnsd"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }
[ -f "${CONFIG_FILE}" ] || { err "RNS config not found at ${CONFIG_FILE}"; exit 1; }

# Current port: the listen_port inside the first TCPServerInterface block.
OLD_PORT="$(awk '
    /^[[:space:]]*\[\[/ { in_srv = 0 }
    /type[[:space:]]*=[[:space:]]*TCPServerInterface/ { in_srv = 1 }
    in_srv && /listen_port[[:space:]]*=/ { sub(/.*=[[:space:]]*/, ""); print; exit }
' "${CONFIG_FILE}")"
[ -n "${OLD_PORT}" ] || { err "No TCPServerInterface with a listen_port found in ${CONFIG_FILE}"; exit 1; }

# New port: argument or prompt.
NEW_PORT="${1:-}"
if [ -z "${NEW_PORT}" ]; then
    printf 'Current TCPServerInterface port: %s\n' "${OLD_PORT}"
    printf 'New port [4242]: '
    if [ -r /dev/tty ]; then read NEW_PORT < /dev/tty || true; else read NEW_PORT || true; fi
    NEW_PORT="${NEW_PORT:-4242}"
fi
case "${NEW_PORT}" in
    ''|*[!0-9]*) err "Port must be a number: '${NEW_PORT}'"; exit 1 ;;
esac
[ "${NEW_PORT}" -ge 1 ] && [ "${NEW_PORT}" -le 65535 ] || { err "Port out of range: ${NEW_PORT}"; exit 1; }
if [ "${NEW_PORT}" = "${OLD_PORT}" ]; then
    log "Port is already ${OLD_PORT}; nothing to do."
    exit 0
fi

# 1. Is the new port free? (ignore rnsd itself)
if command -v ss >/dev/null 2>&1; then
    if ss -tlnp | grep -q ":${NEW_PORT} " ; then
        if ! ss -tlnp | grep ":${NEW_PORT} " | grep -q "\"${SERVICE_NAME}\""; then
            err "Something else is already listening on TCP ${NEW_PORT}:"
            ss -tlnp | grep ":${NEW_PORT} " >&2
            exit 1
        fi
    fi
else
    warn "'ss' not found — skipping the port-in-use check"
fi

# 2. Rewrite the config (backup first). Only the TCPServerInterface block is touched.
BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "${CONFIG_FILE}" "${BACKUP}"
log "Backup: ${BACKUP}"
awk -v new="${NEW_PORT}" '
    /^[[:space:]]*\[\[/ { in_srv = 0 }
    /type[[:space:]]*=[[:space:]]*TCPServerInterface/ { in_srv = 1 }
    in_srv && /listen_port[[:space:]]*=/ && !done {
        sub(/listen_port[[:space:]]*=[[:space:]]*[0-9]+/, "listen_port = " new); done = 1
    }
    { print }
' "${BACKUP}" > "${CONFIG_FILE}"
chown --reference="${BACKUP}" "${CONFIG_FILE}" 2>/dev/null || true
chmod --reference="${BACKUP}" "${CONFIG_FILE}" 2>/dev/null || true
log "listen_port: ${OLD_PORT} -> ${NEW_PORT} in ${CONFIG_FILE}"

# 3. Restart rnsd.
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    log "Restarting ${SERVICE_NAME} (systemd)..."
    systemctl restart "${SERVICE_NAME}.service"
elif command -v rc-service >/dev/null 2>&1; then
    log "Restarting ${SERVICE_NAME} (OpenRC)..."
    rc-service "${SERVICE_NAME}" restart
else
    err "Neither systemd nor OpenRC found — restart ${SERVICE_NAME} yourself."
    exit 1
fi

# Verify the listener (give rnsd a moment to bind).
i=0; ok=0
while [ $i -lt 10 ]; do
    if command -v ss >/dev/null 2>&1 && ss -tlnp | grep ":${NEW_PORT} " | grep -q "\"${SERVICE_NAME}\""; then ok=1; break; fi
    i=$((i + 1)); sleep 1
done
if [ "$ok" -eq 1 ]; then
    log "rnsd is listening on TCP ${NEW_PORT}"
elif command -v ss >/dev/null 2>&1; then
    err "rnsd is not listening on ${NEW_PORT} after restart. Check: journalctl -u ${SERVICE_NAME} -n 30  (or ${RNS_CONFIG_DIR}/logfile)"
    err "To roll back: cp ${BACKUP} ${CONFIG_FILE} && systemctl restart ${SERVICE_NAME}"
    exit 1
else
    warn "Cannot verify the listener without 'ss'; check manually."
fi

# 4. Firewall (ufw only — others are too varied to guess).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ufw status | grep -q "^${OLD_PORT}/tcp"; then
        log "ufw: replacing rule ${OLD_PORT}/tcp -> ${NEW_PORT}/tcp"
        ufw delete allow "${OLD_PORT}/tcp" >/dev/null
        ufw allow "${NEW_PORT}/tcp" >/dev/null
    else
        warn "ufw is active but had no rule for ${OLD_PORT}/tcp — add one if peers should reach you: ufw allow ${NEW_PORT}/tcp"
    fi
else
    warn "No active ufw — if another firewall is in use, allow inbound TCP ${NEW_PORT} and drop ${OLD_PORT}."
fi

cat <<EOF

------------------------------------------------------------
 TCPServerInterface now on port ${NEW_PORT} (was ${OLD_PORT}).
   config  : ${CONFIG_FILE}
   backup  : ${BACKUP}
 lxmd / analog-notifier reconnect to the shared instance by themselves.
 Peers that dial you by address need the new port: <host>:${NEW_PORT}
------------------------------------------------------------
EOF
