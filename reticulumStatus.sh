#!/bin/sh
#
# reticulumStatus.sh — Reticulum + LXMF status for the node, from the right user and config.
#
# `rnstatus` on its own reads ~/.reticulum and starts a second Reticulum instance as root,
# which is not the node. This runs rnstatus and `lxmd --status` as the service user against
# the service configs, so both talk to the live daemons: interfaces and their peers first, then
# the propagation node's hash, uptime, store and peers.
#
# Usage:
#   sudo ./reticulumStatus.sh              Interfaces (rnstatus) + propagation node (lxmd --status)
#   sudo ./reticulumStatus.sh --paths      Path table instead (rnpath -t): who is reachable via whom
#   sudo ./reticulumStatus.sh -a           Any rnstatus flag → rnstatus only, with that flag
#

set -eu

RNS_USER="${RNS_USER:-reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-/var/lib/reticulum/.reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-/var/lib/reticulum/.lxmd}"

err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
case "${1:-}" in -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || { err "Run as root (sudo $0)"; exit 1; }
[ -f "${RNS_CONFIG_DIR}/config" ] || { err "RNS config not found at ${RNS_CONFIG_DIR}/config"; exit 1; }

as_service_user() { su -s /bin/sh "${RNS_USER}" -c "$*"; }

case "${1:-}" in
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --paths) shift; as_service_user "rnpath --config '${RNS_CONFIG_DIR}' -t $*" ;;
    "")
        as_service_user "rnstatus --config '${RNS_CONFIG_DIR}'"
        if [ -f "${LXMD_CONFIG_DIR}/config" ]; then
            echo
            as_service_user "lxmd --status --config '${LXMD_CONFIG_DIR}' --rnsconfig '${RNS_CONFIG_DIR}'"
        fi ;;
    *) as_service_user "rnstatus --config '${RNS_CONFIG_DIR}' $*" ;;
esac
