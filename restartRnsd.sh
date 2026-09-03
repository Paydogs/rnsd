#!/bin/sh
#
# restartRnsd.sh — restart the Reticulum transport node and everything that joins its shared instance.
#
# Order matters: lxmd and the notifier hang if rnsd restarts underneath them, so they are
# stopped first, rnsd is restarted, and they are started again once it is up. Afterwards the
# read-out is what tells you the node is really back — service states, rnstatus, lxmd's own
# status, the size of the path table, and the TCP listener (a config typo shows up as "running
# but nothing bound", which the service manager alone will not say). clearLxmd.sh and
# editRnsConfig.sh end by running this.
#
# Usage:  sudo ./restartRnsd.sh
#

set -eu

RNS_USER="${RNS_USER:-reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-/var/lib/reticulum/.reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-/var/lib/reticulum/.lxmd}"
NOTIFIER_NAME="${NOTIFIER_NAME:-analog-notifier}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

case "${1:-}" in
    "") ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown argument: $1 (try --help)"; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT=systemd; else INIT=openrc; fi
svc_present() { if [ "$INIT" = systemd ]; then [ -f "/etc/systemd/system/$1.service" ]; else [ -f "/etc/init.d/$1" ]; fi; }
svc_stop()    { if [ "$INIT" = systemd ]; then systemctl stop "$1.service"; else rc-service "$1" stop; fi; }
svc_start()   { if [ "$INIT" = systemd ]; then systemctl start "$1.service"; else rc-service "$1" start; fi; }
svc_restart() { if [ "$INIT" = systemd ]; then systemctl restart "$1.service"; else rc-service "$1" restart; fi; }
svc_active()  { if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$1.service"; else rc-service "$1" status >/dev/null 2>&1; fi; }
as_service_user() { su -s /bin/sh "${RNS_USER}" -c "$*"; }

# Dependants down first, rnsd restarted, dependants up — the reverse of what a plain restart
# of all three would do, and the only order in which none of them hangs.
for svc in "${NOTIFIER_NAME}" lxmd; do
    svc_present "${svc}" || continue
    log "Stopping ${svc}..."; svc_stop "${svc}" || warn "${svc} was not running"
done
log "Restarting rnsd..."
svc_restart rnsd
sleep 3
for svc in lxmd "${NOTIFIER_NAME}"; do
    svc_present "${svc}" || continue
    log "Starting ${svc}..."; svc_start "${svc}" || warn "${svc} failed to start"
done
sleep 5

for svc in rnsd lxmd "${NOTIFIER_NAME}"; do
    svc_present "${svc}" || continue
    if svc_active "${svc}"; then log "${svc}: running"; else err "${svc}: NOT running"; fi
done

# The listener check, same rule as checkHealth.sh: rnsd shows up in `ss` as python3, so match
# on the port being bound rather than on a process name.
port="$(awk '/^[[:space:]]*\[\[/{s=0} /type[[:space:]]*=[[:space:]]*TCPServerInterface/{s=1} s&&/listen_port[[:space:]]*=/{sub(/.*=[[:space:]]*/,"");print;exit}' "${RNS_CONFIG_DIR}/config" 2>/dev/null || true)"
if [ -n "${port}" ] && command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -q ":${port} "; then log "TCPServerInterface listening on ${port}"
    else warn "nothing listening on TCP ${port} — check: $( [ "$INIT" = systemd ] && echo 'journalctl -u rnsd -n 30' || echo 'tail -n 30 /var/log/rnsd.log' )"; fi
fi

echo
as_service_user "rnstatus --config '${RNS_CONFIG_DIR}'" || warn "rnstatus failed"
if svc_present lxmd; then
    echo
    as_service_user "lxmd --status --config '${LXMD_CONFIG_DIR}' --rnsconfig '${RNS_CONFIG_DIR}'" || warn "lxmd --status failed"
fi
printf 'paths in table: '; as_service_user "rnpath -t --config '${RNS_CONFIG_DIR}'" | wc -l | tr -d ' '
