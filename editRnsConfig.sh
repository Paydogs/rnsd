#!/bin/sh
#
# editRnsConfig.sh — edit rnsd's config in place and restart what depends on it.
#
# Opens the service config in $EDITOR (nano by default) after taking a timestamped backup.
# If the file changed, the owner is restored to the service user (some editors recreate the
# file as root, and rnsd cannot read what it does not own) and the chain is restarted through
# restartRnsd.sh — rnsd, then lxmd and the notifier, which ride its shared instance. Unchanged:
# nothing restarts.
#
# Usage:
#   sudo ./editRnsConfig.sh                 Edit; restart on change (asks)
#   sudo ./editRnsConfig.sh --restart       Edit; restart on change without asking
#   sudo ./editRnsConfig.sh --no-restart    Edit only
#

set -eu

RNS_USER="${RNS_USER:-reticulum}"
RNS_GROUP="${RNS_GROUP:-reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-/var/lib/reticulum/.reticulum}"
CONFIG_FILE="${RNS_CONFIG_DIR}/config"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

case "${1:-}" in -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }
[ -f "${CONFIG_FILE}" ] || { err "RNS config not found at ${CONFIG_FILE}"; exit 1; }
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
    --no-restart) warn "not restarted — the change takes effect on the next rnsd restart"; exit 0 ;;
    --restart) ;;
    *) printf 'Restart rnsd, lxmd and the notifier now? [Y/n] '
       read -r answer </dev/tty || answer=""
       case "${answer}" in n|N|no|NO) warn "not restarted — run restartRnsd.sh when ready"; exit 0 ;; esac ;;
esac

# Prefer the sibling helper (same directory, or on the PATH) so the restart logic lives once.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -x "${HERE}/restartRnsd.sh" ]; then exec "${HERE}/restartRnsd.sh"
elif command -v restartRnsd.sh >/dev/null 2>&1; then exec restartRnsd.sh
fi
for svc in rnsd lxmd analog-notifier; do
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        [ -f "/etc/systemd/system/${svc}.service" ] && systemctl restart "${svc}.service"
    else
        [ -f "/etc/init.d/${svc}" ] && rc-service "${svc}" restart
    fi
done
log "chain restarted"
