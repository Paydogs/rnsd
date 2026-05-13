#!/bin/sh
#
# install-reticulum.sh
#
# Installs Reticulum Network Stack (rnsd) on Alpine Linux,
# generates an example configuration, and sets it up as an
# OpenRC service that starts on boot and auto-restarts on failure.
#
# Usage:  sudo ./install-reticulum.sh
#
# Tested on Alpine 3.19+ (uses OpenRC and the supervise-daemon helper).

set -eu

# ---------- Configurable knobs ----------------------------------------------
RNS_USER="${RNS_USER:-reticulum}"
RNS_GROUP="${RNS_GROUP:-reticulum}"
RNS_HOME="${RNS_HOME:-/var/lib/reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-${RNS_HOME}/.reticulum}"
SERVICE_NAME="rnsd"
# ----------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

# All work happens inside main() and main is only invoked on the final
# line of the file. If this script is truncated mid-download (e.g. when
# fetched via `curl ... | sh` and the connection drops), the shell
# will fail to parse an incomplete function body before main is ever
# called, so nothing partial executes.
main() {

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (try: sudo $0)"
    exit 1
fi

# Sanity check: Alpine + OpenRC
if [ ! -f /etc/alpine-release ]; then
    warn "This does not look like Alpine Linux. Continuing anyway..."
fi
if ! command -v rc-update >/dev/null 2>&1; then
    err "OpenRC (rc-update) not found. This script requires Alpine/OpenRC."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. System dependencies
# ---------------------------------------------------------------------------
log "Updating apk index and installing system dependencies..."
# apk update can return non-zero if one of several configured mirrors is
# unreachable, even when other mirrors succeed and the index is usable.
# Don't let that kill the script under 'set -e' — only 'apk add' matters.
apk update || warn "apk update reported errors (likely a stale/unreachable mirror) — continuing"

# Core deps that must succeed
apk add --no-cache python3 py3-pip shadow openrc

# Optional native Python deps — these speed up pip install and avoid
# compiling C extensions. Package names have shifted between Alpine
# releases (py3-serial -> py3-pyserial, etc.), so try each one
# individually and fall back to pip if the apk package isn't available.
log "Installing native Python deps (best-effort — pip will fill in any gaps)..."
need_build_tools=0
for pkg in py3-cryptography py3-netifaces py3-pyserial; do
    if apk add --no-cache "${pkg}" 2>/dev/null; then
        log "  installed ${pkg}"
    else
        warn "  ${pkg} not available in apk — pip will build it from source"
        need_build_tools=1
    fi
done

if [ "${need_build_tools}" -eq 1 ]; then
    log "Installing build toolchain so pip can compile missing deps..."
    apk add --no-cache \
        gcc musl-dev python3-dev libffi-dev openssl-dev \
        cargo rust make pkgconf
fi

# ---------------------------------------------------------------------------
# 2. Service user
# ---------------------------------------------------------------------------
if ! getent group  "${RNS_GROUP}" >/dev/null 2>&1; then
    log "Creating group '${RNS_GROUP}'"
    addgroup -S "${RNS_GROUP}"
fi
if ! id -u "${RNS_USER}" >/dev/null 2>&1; then
    log "Creating system user '${RNS_USER}' with home ${RNS_HOME}"
    adduser -S -D -H -h "${RNS_HOME}" -s /sbin/nologin -G "${RNS_GROUP}" "${RNS_USER}"
fi
mkdir -p "${RNS_HOME}" "${RNS_CONFIG_DIR}"
chown -R "${RNS_USER}:${RNS_GROUP}" "${RNS_HOME}"
chmod 750 "${RNS_HOME}"

# ---------------------------------------------------------------------------
# 3. Install Reticulum (rns) via pip
#    Alpine's Python is PEP-668 externally-managed, so we use
#    --break-system-packages to install globally (so /usr/bin/rnsd exists).
# ---------------------------------------------------------------------------
log "Installing/upgrading Reticulum (rns) and LXMF via pip..."
pip3 install --upgrade --break-system-packages rns lxmf

RNSD_BIN="$(command -v rnsd || true)"
if [ -z "${RNSD_BIN}" ]; then
    err "rnsd binary not found on PATH after installation."
    exit 1
fi
log "rnsd installed at ${RNSD_BIN}"

# Stop any existing rnsd service so it can't regenerate a default
# config while we're writing ours.
if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
    log "Stopping existing ${SERVICE_NAME} service before reconfiguring..."
    rc-service "${SERVICE_NAME}" stop || true
fi

# ---------------------------------------------------------------------------
# 4. Generate the example config (rnsd --exampleconfig) on first install
# ---------------------------------------------------------------------------
CONFIG_FILE="${RNS_CONFIG_DIR}/config"
HOSTNAME_SLUG="$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"

if [ -f "${CONFIG_FILE}" ]; then
    BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backing up existing config -> ${BACKUP}"
    cp -a "${CONFIG_FILE}" "${BACKUP}"
fi

log "Writing config at ${CONFIG_FILE}"
cat > "${CONFIG_FILE}" <<EOF
# Reticulum configuration
# Generated by install-reticulum.sh
# See https://markqvist.github.io/Reticulum/manual/ for full reference.

[reticulum]

  enable_transport = Yes

  share_instance = Yes
  instance_name = ${HOSTNAME_SLUG}

  discover_interfaces = yes


[logging]
  loglevel = 4


[interfaces]

  [[Default Interface]]
    type = AutoInterface
    enabled = Yes

  [[Local TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 0.0.0.0
    listen_port = 7822

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

# ---------------------------------------------------------------------------
# 5. Write the OpenRC init script
#    Uses supervise-daemon, which gives us automatic restart on crash
#    (equivalent to systemd's Restart=always). The 'default' runlevel
#    + rc-update enable handles restart-after-reboot.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 6. Enable on boot + start now
# ---------------------------------------------------------------------------
log "Enabling ${SERVICE_NAME} at the 'default' runlevel (start on boot)"
rc-update add "${SERVICE_NAME}" default

# Restart so we pick up the just-written init script / new config
if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
    log "Restarting ${SERVICE_NAME}..."
    rc-service "${SERVICE_NAME}" restart
else
    log "Starting ${SERVICE_NAME}..."
    rc-service "${SERVICE_NAME}" start
fi

# Brief pause, then show status
sleep 2
rc-service "${SERVICE_NAME}" status || true

cat <<EOF

------------------------------------------------------------
 Reticulum has been installed and is running as a service.

   Service name : ${SERVICE_NAME}
   Run as user  : ${RNS_USER}
   Config file  : ${CONFIG_FILE}
   Log file     : /var/log/${SERVICE_NAME}.log

 Useful commands:
   rc-service ${SERVICE_NAME} status
   rc-service ${SERVICE_NAME} restart
   rc-service ${SERVICE_NAME} stop
   tail -f /var/log/${SERVICE_NAME}.log

 Edit the config, then restart the service:
   \$EDITOR ${CONFIG_FILE}
   rc-service ${SERVICE_NAME} restart

 Configured interfaces:
   - AutoInterface        (LAN auto-discovery, link-local IPv6)
   - TCPServerInterface   (listening on 0.0.0.0:7822)
   - 5x TCPClientInterface  (Beleth, Ether Whisperer, Catz, RMAP, US-East)
   - 2x BackboneInterface   (bnZ-NODE01 Gothenburg, Pleiades Inc.)

 If you have a firewall (awall/iptables/nftables), allow inbound TCP 7822
 so other peers can reach your TCPServerInterface.
------------------------------------------------------------
EOF

# ---------------------------------------------------------------------------
# Add rnstatus alias so plain `rnstatus` works without --config flag
# ---------------------------------------------------------------------------
echo "alias rnstatus='rnstatus --config /var/lib/reticulum/.reticulum'" >> ~/.bashrc
# shellcheck disable=SC1090,SC1091
. ~/.bashrc

} # end of main()

main "$@"
