#!/bin/sh
#
# editLxmdConfig.sh — edit the propagation node's config in place and restart lxmd on change.
#
# Opens lxmd's config in $EDITOR (nano by default) after taking a timestamped backup. If the
# file changed, the owner is restored to the service user (an editor that recreates the file
# leaves it root-owned and unreadable to lxmd) and lxmd is restarted through restartLxmd.sh,
# which takes the notifier with it. rnsd is never touched — it does not read this file.
# Unchanged: nothing restarts.
#
# Usage:
#   sudo ./editLxmdConfig.sh                Edit; restart on change (asks)
#   sudo ./editLxmdConfig.sh --restart      Edit; restart on change without asking
#   sudo ./editLxmdConfig.sh --no-restart   Edit only
#

set -eu

RNS_USER="${RNS_USER:-reticulum}"
RNS_GROUP="${RNS_GROUP:-reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-/var/lib/reticulum/.lxmd}"
CONFIG_FILE="${LXMD_CONFIG_DIR}/config"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

case "${1:-}" in -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }
[ -f "${CONFIG_FILE}" ] || { err "lxmd config not found at ${CONFIG_FILE}"; exit 1; }
MODE="${1:-ask}"

BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "${CONFIG_FILE}" "${BACKUP}"
"${EDITOR:-nano}" "${CONFIG_FILE}"

if cmp -s "${CONFIG_FILE}" "${BACKUP}"; then
    rm -f "${BACKUP}"
    log "no changes"
    exit 0
fi
chown "${RNS_USER}:${RNS_GROUP}" "${CONFIG_FILE}"; chmod 640 "${CONFIG_FILE}"
log "config changed (backup: ${BACKUP})"

case "${MODE}" in
    --no-restart) warn "not restarted — the change takes effect on the next lxmd restart"; exit 0 ;;
    --restart) ;;
    *) printf 'Restart lxmd (and the notifier) now? [Y/n] '
       read -r answer </dev/tty || answer=""
       case "${answer}" in n|N|no|NO) warn "not restarted — run restartLxmd.sh when ready"; exit 0 ;; esac ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -x "${HERE}/restartLxmd.sh" ]; then exec "${HERE}/restartLxmd.sh"
elif command -v restartLxmd.sh >/dev/null 2>&1; then exec restartLxmd.sh
elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl restart lxmd.service; log "lxmd restarted"
else rc-service lxmd restart; log "lxmd restarted"
fi
