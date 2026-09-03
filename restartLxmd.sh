#!/bin/sh
#
# restartLxmd.sh — restart the LXMF propagation node and the notifier, and show they came back.
#
# The notifier is restarted with lxmd: it watches lxmd's message store and treats everything
# older than its own start as backlog, so a fresh start keeps the two in step. rnsd is untouched
# — lxmd is a client of its shared instance and rejoins on its own. Afterwards lxmd's own status
# is printed — node hash, uptime, store size — which is the proof it is serving again, not just
# "active" in the service manager's eyes.
#
# Usage:  sudo ./restartLxmd.sh
#

set -eu

RNS_USER="${RNS_USER:-reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-/var/lib/reticulum/.reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-/var/lib/reticulum/.lxmd}"
NOTIFIER_NAME="${NOTIFIER_NAME:-analog-notifier}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

case "${1:-}" in -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT=systemd; else INIT=openrc; fi
svc_present() { if [ "$INIT" = systemd ]; then [ -f "/etc/systemd/system/$1.service" ]; else [ -f "/etc/init.d/$1" ]; fi; }
svc_restart() { if [ "$INIT" = systemd ]; then systemctl restart "$1.service"; else rc-service "$1" restart; fi; }
svc_active()  { if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$1.service"; else rc-service "$1" status >/dev/null 2>&1; fi; }
svc_present lxmd || { err "lxmd is not installed here"; exit 1; }

log "Restarting lxmd..."
svc_restart lxmd
if svc_present "${NOTIFIER_NAME}"; then log "Restarting ${NOTIFIER_NAME}..."; svc_restart "${NOTIFIER_NAME}" || warn "${NOTIFIER_NAME} restart failed"; fi

# lxmd needs a moment to join the shared instance before --status answers.
sleep 5
for svc in lxmd "${NOTIFIER_NAME}"; do
    svc_present "${svc}" || continue
    if svc_active "${svc}"; then log "${svc}: running"; else err "${svc}: NOT running"; fi
done
out="$(su -s /bin/sh "${RNS_USER}" -c "lxmd --status --config '${LXMD_CONFIG_DIR}' --rnsconfig '${RNS_CONFIG_DIR}'" 2>&1)" || {
    err "lxmd --status failed:"; printf '%s\n' "${out}" | tail -3 | sed 's/^/    /'
    echo "  check: $( [ "$INIT" = systemd ] && echo 'journalctl -u lxmd -n 30' || echo "tail -n 30 ${LXMD_CONFIG_DIR}/logfile" )"
    exit 1
}
printf '%s\n' "${out}"
