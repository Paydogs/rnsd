#!/bin/sh
#
# clearLxmd.sh — clean-slate the node's learned network state, then restart the chain.
#
# Removes rnsd's persisted path table and tunnels and lxmd's persisted peer list, so the node
# relearns the network from live announces instead of a table full of week-old entries (a path
# is only forgotten after seven days; a table that once heard the public mesh keeps it that
# long). Identities, configs and the message store are kept. With --messages the LXMF message
# store goes too — mail recipients never came for, plus the foreign backlog synced from public
# propagation nodes — which is unrecoverable, so that flag asks first unless --yes.
#
# The whole chain is stopped for the wipe: rnsd rewrites its tables on shutdown, so deleting
# them under a running rnsd would only see them written back. restartRnsd.sh brings rnsd, lxmd
# and the notifier up again.
#
# Usage:
#   sudo ./clearLxmd.sh                 path table + tunnels + lxmd peers
#   sudo ./clearLxmd.sh --messages      additionally empties the message store (asks)
#   sudo ./clearLxmd.sh --messages --yes   …without asking
#

set -eu

RNS_STORE="${RNS_STORE:-/var/lib/reticulum/.reticulum/storage}"
LXMF_STORE="${LXMF_STORE:-/var/lib/reticulum/.lxmd/storage/lxmf}"
NOTIFIER_NAME="${NOTIFIER_NAME:-analog-notifier}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

WIPE_MESSAGES=no; YES=no
for a in "$@"; do
    case "$a" in
        --messages) WIPE_MESSAGES=yes ;;
        --yes) YES=yes ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown argument: $a (try --help)"; exit 2 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }

if [ "${WIPE_MESSAGES}" = yes ]; then
    count="$(find "${LXMF_STORE}/messagestore" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${YES}" != yes ] && [ "${count}" -gt 0 ]; then
        printf '%s message(s) in %s/messagestore will be deleted for good. Continue? [y/N] ' "${count}" "${LXMF_STORE}"
        read -r answer </dev/tty || answer=""
        case "${answer}" in y|Y|yes|YES) ;; *) echo "Nothing done."; exit 0 ;; esac
    fi
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT=systemd; else INIT=openrc; fi
svc_present() { if [ "$INIT" = systemd ]; then [ -f "/etc/systemd/system/$1.service" ]; else [ -f "/etc/init.d/$1" ]; fi; }
svc_stop()    { if [ "$INIT" = systemd ]; then systemctl stop "$1.service"; else rc-service "$1" stop; fi; }

# Dependants first, rnsd last — the reverse of start order.
for svc in "${NOTIFIER_NAME}" lxmd rnsd; do
    svc_present "${svc}" || continue
    log "Stopping ${svc}..."; svc_stop "${svc}" || warn "${svc} was not running"
done

for f in "${RNS_STORE}/destination_table" "${RNS_STORE}/tunnels" "${LXMF_STORE}/peers"; do
    if [ -e "$f" ]; then log "removing $f"; rm -f "$f"; else log "absent   $f"; fi
done

if [ "${WIPE_MESSAGES}" = yes ]; then
    log "removing ${count} message(s) from ${LXMF_STORE}/messagestore"
    find "${LXMF_STORE}/messagestore" -type f -delete
fi

# Prefer the sibling helper (same directory, or on the PATH) so the restart logic lives once.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -x "${HERE}/restartRnsd.sh" ]; then exec "${HERE}/restartRnsd.sh"
elif command -v restartRnsd.sh >/dev/null 2>&1; then exec restartRnsd.sh
fi
log "Starting rnsd, lxmd, ${NOTIFIER_NAME}..."
for svc in rnsd lxmd "${NOTIFIER_NAME}"; do
    svc_present "${svc}" || continue
    if [ "$INIT" = systemd ]; then systemctl start "${svc}.service"; else rc-service "${svc}" start; fi
done
