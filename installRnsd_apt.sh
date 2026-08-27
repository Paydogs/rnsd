#!/bin/bash
#
# install-reticulum.sh  (Debian / Ubuntu variant)
#
# Installs Reticulum Network Stack (rnsd) on Debian or Ubuntu,
# generates an example configuration with custom interfaces, and
# sets it up as a systemd service that starts on boot and
# auto-restarts on failure.
#
# Usage:  sudo ./install-reticulum.sh
#
# Tested on:
#   - Debian 12 (Bookworm) and 13 (Trixie)  -- PEP 668 / externally-managed
#   - Debian 11 (Bullseye)                  -- legacy, no PEP 668
#   - Ubuntu 22.04, 24.04
#

set -euo pipefail

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
# fetched via `curl ... | sudo bash` and the connection drops), bash
# will fail to parse an incomplete function body before main is ever
# called, so nothing partial executes.
main() {

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root (try: sudo $0)"
    exit 1
fi

# Sanity check: Debian-family + systemd
if ! command -v apt-get >/dev/null 2>&1; then
    err "apt-get not found. This script is for Debian/Ubuntu systems."
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl not found. This script requires a systemd-based system."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. System dependencies
# ---------------------------------------------------------------------------
log "Updating apt index and installing system dependencies..."
apt-get update -y

# Core packages (python3 + pip). python3-full is needed on modern Debian
# so that 'python3 -m venv' works, in case we fall back to a venv install.
apt-get install -y --no-install-recommends \
    ca-certificates \
    python3 \
    python3-pip \
    python3-full \
    adduser

# Native Python deps via apt — much faster than letting pip compile them.
# Try each individually so package renames between releases don't kill
# the whole install. Anything missing will be installed by pip later.
log "Installing native Python deps from apt (best-effort)..."
need_build_tools=0
for pkg in python3-cryptography python3-netifaces python3-serial; do
    if apt-get install -y --no-install-recommends "${pkg}" 2>/dev/null; then
        log "  installed ${pkg}"
    else
        warn "  ${pkg} not available via apt — pip will build it from source"
        need_build_tools=1
    fi
done

if [ "${need_build_tools}" -eq 1 ]; then
    log "Installing build toolchain so pip can compile missing deps..."
    apt-get install -y --no-install-recommends \
        build-essential python3-dev libffi-dev libssl-dev cargo rustc pkg-config
fi

# ---------------------------------------------------------------------------
# 2. Service user
# ---------------------------------------------------------------------------
if ! getent group "${RNS_GROUP}" >/dev/null 2>&1; then
    log "Creating group '${RNS_GROUP}'"
    addgroup --system "${RNS_GROUP}"
fi
if ! id -u "${RNS_USER}" >/dev/null 2>&1; then
    log "Creating system user '${RNS_USER}' with home ${RNS_HOME}"
    adduser --system --group --no-create-home \
            --home "${RNS_HOME}" \
            --shell /usr/sbin/nologin \
            --ingroup "${RNS_GROUP}" \
            "${RNS_USER}" || \
    adduser --system --no-create-home \
            --home "${RNS_HOME}" \
            --shell /usr/sbin/nologin \
            --ingroup "${RNS_GROUP}" \
            "${RNS_USER}"
fi
mkdir -p "${RNS_HOME}" "${RNS_CONFIG_DIR}"
chown -R "${RNS_USER}:${RNS_GROUP}" "${RNS_HOME}"
chmod 750 "${RNS_HOME}"

# ---------------------------------------------------------------------------
# 3. Install Reticulum (rns) via pip
#    On Debian 12+ / Ubuntu 23.04+ the system Python is PEP-668
#    "externally-managed", so we need --break-system-packages to
#    install rns globally (so /usr/local/bin/rnsd ends up on PATH).
#    On older systems that flag is unknown but harmless — we detect
#    and use it only when the marker file is present.
# ---------------------------------------------------------------------------
PIP_FLAGS=""
if find /usr/lib/python3*/EXTERNALLY-MANAGED -maxdepth 1 2>/dev/null | grep -q .; then
    log "Detected PEP 668 EXTERNALLY-MANAGED marker — using --break-system-packages"
    PIP_FLAGS="--break-system-packages"
fi

log "Installing/upgrading Reticulum (rns) and LXMF via pip..."
# lxmf is required when discover_interfaces=yes, and is useful in general
# for any LXMF-based clients on the network.
# shellcheck disable=SC2086
pip3 install --upgrade ${PIP_FLAGS} rns lxmf

RNSD_BIN="$(command -v rnsd || true)"
if [ -z "${RNSD_BIN}" ]; then
    # pip sometimes installs scripts into /usr/local/bin which may not
    # be on root's PATH in minimal Debian containers — check explicitly.
    for candidate in /usr/local/bin/rnsd /usr/bin/rnsd; do
        if [ -x "${candidate}" ]; then
            RNSD_BIN="${candidate}"
            break
        fi
    done
fi
if [ -z "${RNSD_BIN}" ]; then
    err "rnsd binary not found on PATH after installation."
    exit 1
fi
log "rnsd installed at ${RNSD_BIN}"

# ---------------------------------------------------------------------------
# 3b. Stop any existing rnsd service so it can't regenerate a default
#     config while we're writing ours.
# ---------------------------------------------------------------------------
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        log "Stopping existing ${SERVICE_NAME} service before reconfiguring..."
        systemctl stop "${SERVICE_NAME}.service" || true
    fi
fi

# ---------------------------------------------------------------------------
# 4. Generate the example config (rnsd --exampleconfig) on first install,
#    then append our custom interfaces.
# ---------------------------------------------------------------------------
CONFIG_FILE="${RNS_CONFIG_DIR}/config"
HOSTNAME_SLUG="$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"

# Back up any existing config (so re-running this script is safe and
# also recovers from a previously-broken config that rnsd may have
# auto-regenerated as a stripped-down default).
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

# ---------------------------------------------------------------------------
# 5. Write the systemd unit file
#    This matches the official unit from the Reticulum manual (with
#    Restart=always and RestartSec=3), adapted for our service user
#    and config path.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 6. Enable on boot + start now
# ---------------------------------------------------------------------------
log "Reloading systemd and enabling ${SERVICE_NAME}..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    log "Restarting ${SERVICE_NAME}..."
    systemctl restart "${SERVICE_NAME}.service"
else
    log "Starting ${SERVICE_NAME}..."
    systemctl start "${SERVICE_NAME}.service"
fi

sleep 2
systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

cat <<EOF

------------------------------------------------------------
 Reticulum has been installed and is running as a service.

   Service name : ${SERVICE_NAME}.service
   Run as user  : ${RNS_USER}
   Config file  : ${CONFIG_FILE}
   Logs         : journalctl -u ${SERVICE_NAME} -f

 Useful commands:
   systemctl status ${SERVICE_NAME}
   systemctl restart ${SERVICE_NAME}
   systemctl stop ${SERVICE_NAME}
   journalctl -u ${SERVICE_NAME} -f

 Edit the config, then restart the service:
   \$EDITOR ${CONFIG_FILE}
   systemctl restart ${SERVICE_NAME}

 Configured interfaces:
   - AutoInterface        (LAN auto-discovery, link-local IPv6)
   - TCPServerInterface   (listening on 0.0.0.0:4242)
   - 5x TCPClientInterface  (Beleth, Ether Whisperer, Catz, RMAP, US-East)
   - 2x BackboneInterface   (bnZ-NODE01 Gothenburg, Pleiades Inc.)

 If you have a firewall (ufw/nftables/iptables), allow inbound TCP 4242
 so other peers can reach your TCPServerInterface, e.g.:
   ufw allow 4242/tcp
------------------------------------------------------------
EOF

# ---------------------------------------------------------------------------
# Add rnstatus alias so plain `rnstatus` works without --config flag
# ---------------------------------------------------------------------------
echo "alias rnstatus='rnstatus --config /var/lib/reticulum/.reticulum'" >> ~/.bashrc
# shellcheck disable=SC1090
source ~/.bashrc

} # end of main()

main "$@"
