#!/bin/sh
#
# checkHealth.sh — one-shot health check for a node installed by install.sh:
# rnsd, lxmd (propagation node) and the Analog APNs notifier.
#
# Prints one PASS / WARN / FAIL line per check and exits non-zero if any
# check FAILed. Safe to run any time; changes nothing.
#
# Usage:  sudo ./checkHealth.sh
#

set -u

RNS_USER="${RNS_USER:-reticulum}"
RNS_HOME="${RNS_HOME:-/var/lib/reticulum}"
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-${RNS_HOME}/.reticulum}"
LXMD_CONFIG_DIR="${LXMD_CONFIG_DIR:-${RNS_HOME}/.lxmd}"
LXMD_STORE_DIR="${LXMD_CONFIG_DIR}/storage/lxmf/messagestore"
NOTIFIER_NAME="analog-notifier"
NOTIFIER_USER="${NOTIFIER_USER:-analog-notifier}"
NOTIFIER_INSTALL_DIR="${NOTIFIER_INSTALL_DIR:-/opt/analog-notifier}"
NOTIFIER_CONF_DIR="${NOTIFIER_CONF_DIR:-/etc/analog}"
NOTIFIER_STATE_DIR="${NOTIFIER_STATE_DIR:-/var/lib/analog-notifier}"
NOTIFIER_CONF="${NOTIFIER_CONF_DIR}/notifier.conf"

FAILS=0; WARNS=0
NODE_HASH=""; NOTIFIER_REG=""
pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo $0) — several checks need it." >&2; exit 1; }

# --- init system helpers -----------------------------------------------------
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT=systemd; else INIT=openrc; fi
svc_active() {
    if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$1.service"; else rc-service "$1" status >/dev/null 2>&1; fi
}
svc_enabled() {
    if [ "$INIT" = systemd ]; then systemctl is-enabled --quiet "$1.service" 2>/dev/null
    else rc-update show default 2>/dev/null | grep -qw "$1"; fi
}
svc_check() {
    if svc_active "$1"; then
        if svc_enabled "$1"; then pass "$1 is running and enabled at boot"
        else warn "$1 is running but NOT enabled at boot"; fi
    else
        fail "$1 is not running"
        if [ "$INIT" = systemd ]; then journalctl -u "$1" -n 5 --no-pager 2>/dev/null | sed 's/^/          /'; fi
    fi
}
# conf_get SECTION KEY (ini, keys at column 0)
conf_get() {
    awk -v sec="[$1]" -v key="$2" '
        /^\[/ { insec = ($0 == sec) }
        insec && $1 == key && $2 == "=" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*[#;].*$/, ""); print; exit }
    ' "${NOTIFIER_CONF}" 2>/dev/null
}

# =============================================================================
section "System"
if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then pass "clock is NTP-synchronised ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
    else warn "clock is NOT NTP-synchronised — APNs rejects JWTs with a skewed clock (timedatectl set-ntp true)"; fi
else
    if pgrep -x chronyd >/dev/null 2>&1 || pgrep -x ntpd >/dev/null 2>&1; then pass "an NTP daemon is running"
    else warn "no NTP daemon found — APNs needs an accurate clock"; fi
fi
if command -v df >/dev/null 2>&1; then
    use="$(df -P "${RNS_HOME}" 2>/dev/null | awk 'NR==2 { sub("%", "", $5); print $5 }')"
    if [ -n "${use}" ]; then
        if [ "${use}" -lt 85 ]; then pass "disk holding ${RNS_HOME} is ${use}% used"
        else warn "disk holding ${RNS_HOME} is ${use}% used"; fi
    fi
fi

# =============================================================================
section "rnsd (Reticulum)"
svc_check rnsd
if [ -f "${RNS_CONFIG_DIR}/config" ]; then
    port="$(awk '/^[[:space:]]*\[\[/{s=0} /type[[:space:]]*=[[:space:]]*TCPServerInterface/{s=1} s&&/listen_port[[:space:]]*=/{sub(/.*=[[:space:]]*/,"");print;exit}' "${RNS_CONFIG_DIR}/config")"
    if [ -n "${port}" ]; then
        if command -v ss >/dev/null 2>&1; then
            # rnsd is a Python script, so the process ss names is "python3", never "rnsd" —
            # matching on the name reported "nothing is bound" against a server with six
            # clients. Match the service's own PID instead, and fall back to "something owns
            # the port" where the PID is unknown (OpenRC).
            listener="$(ss -tlnp 2>/dev/null | grep ":${port} ")"
            rnsd_pid=""
            [ "$INIT" = systemd ] && rnsd_pid="$(systemctl show -p MainPID --value rnsd.service 2>/dev/null)"
            if [ -z "${listener}" ]; then fail "TCPServerInterface should listen on TCP ${port} but nothing is bound"
            elif [ -n "${rnsd_pid}" ] && [ "${rnsd_pid}" != 0 ] && ! printf '%s' "${listener}" | grep -q "pid=${rnsd_pid},"; then
                fail "TCP ${port} is bound, but not by rnsd (pid ${rnsd_pid}) — another process holds the port"
            else pass "TCPServerInterface listening on TCP ${port}"; fi
        else warn "'ss' not available; cannot verify TCP ${port} listener"; fi
    else warn "no TCPServerInterface in ${RNS_CONFIG_DIR}/config (inbound peers cannot reach this node)"; fi
else
    fail "RNS config ${RNS_CONFIG_DIR}/config not found"
fi
if command -v rnstatus >/dev/null 2>&1 && svc_active rnsd; then
    out="$(timeout 20 su -s /bin/sh "${RNS_USER}" -c "rnstatus --config '${RNS_CONFIG_DIR}'" 2>&1)" || true
    # One line per interface, whatever is in the config: rnstatus prints the
    # interface name on its own line (" <Type>[<name>]", one leading space), then indented
    # "Status : Up|Down" and optional "Peers/Clients/Rate/Traffic" lines.
    table="$(printf '%s\n' "${out}" | awk '
        /^ ?[^ ].*\[.*\]$/ { if (name != "") emit(); name = $0; sub(/^ /, "", name); status = "?"; extra = ""; next }
        name != "" && /^ +Status +:/  { sub(/^ +Status +: */, ""); status = $0; next }
        name != "" && /^ +(Peers|Clients) +:/ { sub(/^ +/, ""); sub(/ +: */, ": "); extra = extra (extra == "" ? "" : ", ") $0; next }
        name != "" && /^ +Rate +:/    { sub(/^ +Rate +: */, ""); extra = extra (extra == "" ? "" : ", ") "rate " $0; next }
        function emit() { printf "%s\t%s\t%s\n", status, name, extra }
        END { if (name != "") emit() }
    ')"
    total="$(printf '%s\n' "${table}" | grep -c .)"
    up="$(printf '%s\n' "${table}" | grep -c '^Up')"
    if [ "${total}" -gt 0 ]; then
        if [ "${up}" -eq "${total}" ]; then pass "rnstatus: all ${total} interfaces Up"
        elif [ "${up}" -gt 0 ]; then warn "rnstatus: ${up}/${total} interfaces Up"
        else fail "rnstatus: ${total} interfaces, none Up"; fi
        printf '%s\n' "${table}" | while IFS="$(printf '\t')" read -r st nm ex; do
            case "${st}" in
                Up*)   mark="\033[1;32m up \033[0m" ;;
                Down*) mark="\033[1;31mdown\033[0m" ;;
                *)     mark="\033[1;33m ?  \033[0m" ;;
            esac
            printf "          [${mark}] %s%s\n" "${nm}" "${ex:+  (${ex})}"
        done
    else
        fail "rnstatus could not talk to rnsd: $(printf '%s' "${out}" | tail -1)"
    fi
fi
# identity files must not be world-readable
if [ -d "${RNS_CONFIG_DIR}" ]; then
    leaks="$(find "${RNS_HOME}" -perm -o+r \( -name transport_identity -o -name identity -o -path '*/identities/*' -o -path '*/ratchets/*' \) 2>/dev/null | head -3)"
    if [ -z "${leaks}" ]; then pass "identity files are not world-readable"
    else fail "world-readable identity material under ${RNS_HOME} — run: chmod -R o-rwx ${RNS_HOME}"; printf '%s\n' "${leaks}" | sed 's/^/          /'; fi
fi

# =============================================================================
section "lxmd (propagation node)"
svc_check lxmd
if command -v lxmd >/dev/null 2>&1 && svc_active lxmd; then
    out="$(timeout 30 su -s /bin/sh "${RNS_USER}" -c "lxmd --status --config '${LXMD_CONFIG_DIR}' --rnsconfig '${RNS_CONFIG_DIR}'" 2>&1)" || true
    if printf '%s' "${out}" | grep -q 'Propagation Node running'; then
        pass "$(printf '%s\n' "${out}" | grep 'Propagation Node running' | sed 's/^LXMF //')"
        NODE_HASH="$(printf '%s\n' "${out}" | sed -n 's/.*Propagation Node running on <\([0-9a-f]*\)>.*/\1/p')"
        printf '%s\n' "${out}" | grep -E 'Messagestore contains|Peers   :|available' | sed 's/^ */          /'
        avail="$(printf '%s\n' "${out}" | awk '/available/ { print $1 }')"
        [ -n "${avail}" ] && [ "${avail}" -eq 0 ] && warn "lxmd has 0 available peers (fresh node, or all peers unreachable)"
    else
        fail "lxmd --status failed: $(printf '%s' "${out}" | tail -1)"
    fi
fi
if [ -f "${LXMD_CONFIG_DIR}/logfile" ]; then
    errs="$(tail -n 200 "${LXMD_CONFIG_DIR}/logfile" 2>/dev/null | grep -c '\[Error\]')"
    if [ "${errs}" -eq 0 ]; then pass "no [Error] lines in the last 200 lxmd log lines"
    else warn "${errs} [Error] line(s) in the last 200 lxmd log lines (tail ${LXMD_CONFIG_DIR}/logfile)"; fi
fi
[ -d "${LXMD_STORE_DIR}" ] && pass "message store: $(find "${LXMD_STORE_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ') message(s) in ${LXMD_STORE_DIR}" \
                           || fail "message store dir ${LXMD_STORE_DIR} missing"

# =============================================================================
section "analog-notifier"
if [ -z "${NODE_HASH}" ] && [ -f "${LXMD_CONFIG_DIR}/identity" ]; then
    NODE_HASH="$(su -s /bin/sh "${RNS_USER}" -c "python3 -c \"
import RNS
i = RNS.Identity.from_file('${LXMD_CONFIG_DIR}/identity')
print(RNS.Destination.hash(i, 'lxmf', 'propagation').hex())\"" 2>/dev/null)"
fi
if [ -n "${NODE_HASH}" ]; then
    pass "propagation node identifier (select this node in the Analog app): ${NODE_HASH}"
else
    warn "propagation node identifier unknown (lxmd --status failed and no identity file yet)"
fi
if [ -f "${NOTIFIER_STATE_DIR}/identity" ]; then
    idout="$(su -s /bin/sh "${NOTIFIER_USER}" -c "python3 '${NOTIFIER_INSTALL_DIR}/analog_notifier.py' --config '${NOTIFIER_CONF}' --identity" 2>&1)"
    reg="$(printf '%s\n' "${idout}" | sed -n 's/^registration destination : \([0-9a-f]*\).*/\1/p')"
    if [ -n "${reg}" ]; then
        NOTIFIER_REG="${reg}"
        pass "notifier identity present; registration destination (analog.notifier.register): ${reg}"
        perm="$(stat -c '%a %U' "${NOTIFIER_STATE_DIR}/identity" 2>/dev/null)"
        [ "${perm}" = "600 ${NOTIFIER_USER}" ] || warn "identity file perms are '${perm}', expected '600 ${NOTIFIER_USER}'"
    else
        fail "notifier identity file exists but cannot be read: $(printf '%s' "${idout}" | tail -1)"
    fi
else
    fail "notifier identity missing (${NOTIFIER_STATE_DIR}/identity) — run: install.sh --fix"
fi
# RPC key: rnsd and the notifier's RNS client config must carry the same rpc_key,
# or link identification fails ("digest sent was rejected" → "unidentified").
rk_rnsd="$(sed -n 's/^[[:space:]]*rpc_key[[:space:]]*=[[:space:]]*//p' "${RNS_CONFIG_DIR}/config" 2>/dev/null | head -1)"
rk_noti="$(sed -n 's/^[[:space:]]*rpc_key[[:space:]]*=[[:space:]]*//p' "${NOTIFIER_STATE_DIR}/rns/config" 2>/dev/null | head -1)"
if [ -z "${rk_rnsd}" ]; then fail "rnsd config has no rpc_key — identified requests will be refused as 'unidentified'; run: install.sh --fix"
elif [ "${rk_rnsd}" != "${rk_noti}" ]; then fail "rpc_key differs between rnsd and the notifier's RNS config — run: install.sh --fix"
else pass "rpc_key shared between rnsd and the notifier"; fi
if [ "$INIT" = systemd ] && journalctl -u "${NOTIFIER_NAME}" -n 200 --no-pager -o cat 2>/dev/null | grep -q 'digest sent was rejected'; then
    warn "recent 'digest sent was rejected' RPC errors in the notifier journal — if they persist after --fix + restart, the rpc_keys are out of sync"
fi
# Relay wake: the notifier reads rnsd's path table over remote management, so rnsd must
# allow the notifier identity and the notifier must know rnsd's transport identity.
if grep -q '^[[:space:]]*enable_remote_management[[:space:]]*=[[:space:]]*[Yy]' "${RNS_CONFIG_DIR}/config" 2>/dev/null; then
    pass "rnsd remote management enabled (relay wake can read the path table)"
else
    warn "rnsd remote management is off — relay wake disabled; run: install.sh --fix"
fi
tid_conf="$(conf_get notifier transport_identity)"
if [ -n "${tid_conf}" ]; then pass "notifier knows rnsd's transport identity (${tid_conf})"
else warn "transport_identity not set in notifier.conf — relay wake disabled; run: install.sh --fix"; fi
if [ -n "${NOTIFIER_REG}" ] && command -v rnpath >/dev/null 2>&1 && svc_active rnsd; then
    if timeout 20 su -s /bin/sh "${RNS_USER}" -c "rnpath --config '${RNS_CONFIG_DIR}' -t" 2>/dev/null | grep -qi "${NOTIFIER_REG}"; then
        pass "registration destination is announced (present in rnsd's path table)"
    else
        warn "registration destination not in rnsd's path table yet — the notifier announces every 5 min after start; check: journalctl -u ${NOTIFIER_NAME} -n 20"
    fi
fi
node_conf="$(conf_get notifier propagation_node)"
if [ -n "${node_conf}" ]; then
    if [ -n "${NODE_HASH}" ] && [ "${node_conf}" != "${NODE_HASH}" ]; then
        fail "notifier.conf propagation_node (${node_conf}) differs from the running lxmd node (${NODE_HASH}) — run: install.sh --fix"
    else pass "notifier announces propagation node ${node_conf}"; fi
else
    warn "propagation_node not set in notifier.conf (apps cannot pair notifier and node) — run: install.sh --fix"
fi
svc_check "${NOTIFIER_NAME}"
if ! id -u "${NOTIFIER_USER}" >/dev/null 2>&1; then
    fail "service user ${NOTIFIER_USER} does not exist"
else
    # store access: must read messagestore, must NOT read rnsd's config dir
    if su -s /bin/sh "${NOTIFIER_USER}" -c "ls '${LXMD_STORE_DIR}' >/dev/null 2>&1"; then pass "${NOTIFIER_USER} can read the message store (ACL ok)"
    else fail "${NOTIFIER_USER} cannot read ${LXMD_STORE_DIR} — re-run install.sh (option 3) to re-apply the ACL"; fi
    if su -s /bin/sh "${NOTIFIER_USER}" -c "ls '${RNS_CONFIG_DIR}' >/dev/null 2>&1"; then fail "${NOTIFIER_USER} can read ${RNS_CONFIG_DIR} — run: chmod -R o-rwx ${RNS_HOME}"
    else pass "${NOTIFIER_USER} cannot read rnsd's config/identity dir"; fi
    # a store file must be readable too (default ACL on new files)
    f="$(find "${LXMD_STORE_DIR}" -type f 2>/dev/null | head -1)"
    if [ -n "${f}" ]; then
        if su -s /bin/sh "${NOTIFIER_USER}" -c "head -c 16 '${f}' >/dev/null 2>&1"; then pass "stored message files are readable by ${NOTIFIER_USER}"
        else fail "stored message files are NOT readable by ${NOTIFIER_USER} (default ACL missing) — re-run install.sh option 3"; fi
    fi
fi
if [ -f "${NOTIFIER_CONF}" ]; then
    pass "config present: ${NOTIFIER_CONF}"
    ms="$(conf_get notifier messagestore)"
    if [ -n "${ms}" ] && [ "${ms}" != "${LXMD_STORE_DIR}" ]; then
        fail "notifier.conf watches '${ms}' but lxmd stores messages in ${LXMD_STORE_DIR} — re-run install.sh option 3"
    fi
    configured=0
    for env in production sandbox; do
        missing=""
        for k in team_id key_id bundle_id; do
            v="$(conf_get "apns.${env}" "$k")"
            { [ -z "$v" ] || [ "$v" = REPLACE_ME ]; } && missing="${missing} ${k}"
        done
        keyinfo=""
        if [ -f "${NOTIFIER_CONF_DIR}/apns_p8_${env}.cred" ]; then
            keyinfo="key: encrypted credential"
            [ "$INIT" = systemd ] && [ ! -f "/etc/systemd/system/${NOTIFIER_NAME}.service.d/apns-${env}.conf" ] && missing="${missing} credential-drop-in"
        elif [ -f "$(conf_get "apns.${env}" key_path)" ]; then
            kp="$(conf_get "apns.${env}" key_path)"
            keyinfo="key: file $(stat -c '%a %U' "$kp" 2>/dev/null)"
            [ "$(stat -c '%a' "$kp" 2>/dev/null)" = 400 ] || missing="${missing} key-perms(${kp} should be 0400)"
        else
            missing="${missing} .p8-key"
        fi
        if [ -z "${missing}" ]; then
            pass "[apns.${env}] configured — bundle $(conf_get "apns.${env}" bundle_id), host $(conf_get "apns.${env}" host) (${keyinfo})"
            configured=$((configured + 1))
        else
            warn "[apns.${env}] not configured — missing:${missing}"
        fi
    done
    [ "${configured}" -eq 0 ] && warn "no environment configured: notifier is dormant (install.sh --install-key ...)"
else
    fail "config ${NOTIFIER_CONF} not found"
fi
if [ -f "${NOTIFIER_STATE_DIR}/tokens.json" ]; then
    n="$(python3 -c "import json,sys; d=json.load(open('${NOTIFIER_STATE_DIR}/tokens.json')); print(len(d))" 2>/dev/null)"
    if [ -n "${n}" ]; then
        if [ "${n}" -gt 0 ]; then pass "token DB valid, ${n} registration(s)"; else warn "token DB valid but empty — no device will be pinged yet"; fi
    else fail "token DB ${NOTIFIER_STATE_DIR}/tokens.json is not valid JSON"; fi
else
    warn "token DB ${NOTIFIER_STATE_DIR}/tokens.json missing"
fi
if python3 -c 'import jwt, httpx, h2, cryptography' 2>/dev/null; then pass "python deps importable (jwt, httpx, h2, cryptography)"
else fail "python deps missing — re-run install.sh option 3"; fi
if python3 - <<'PY' 2>/dev/null
import socket, ssl
for host in ("api.push.apple.com", "api.development.push.apple.com"):
    s = socket.create_connection((host, 443), timeout=5)
    ssl.create_default_context().wrap_socket(s, server_hostname=host).close()
PY
then pass "APNs hosts reachable on 443 (TLS ok)"
else fail "cannot reach APNs on 443 — check egress firewall / DNS"; fi
if [ "$INIT" = systemd ] && svc_active "${NOTIFIER_NAME}"; then
    last="$(journalctl -u "${NOTIFIER_NAME}" -n 3 --no-pager -o cat 2>/dev/null | tail -3)"
    [ -n "${last}" ] && printf '%s\n' "${last}" | sed 's/^/          log: /'
fi

# =============================================================================
printf '\n'
[ -n "${NODE_HASH}" ]    && printf 'Propagation node for the Analog app   : \033[1m%s\033[0m\n' "${NODE_HASH}"
[ -n "${NOTIFIER_REG}" ] && printf 'Notifier registration destination     : \033[1m%s\033[0m  (analog.notifier.register)\n' "${NOTIFIER_REG}"
if [ "${FAILS}" -eq 0 ] && [ "${WARNS}" -eq 0 ]; then printf '\033[1;32mAll checks passed.\033[0m\n'
elif [ "${FAILS}" -eq 0 ]; then printf '\033[1;33m%s warning(s), no failures.\033[0m\n' "${WARNS}"
else printf '\033[1;31m%s failure(s), %s warning(s).\033[0m\n' "${FAILS}" "${WARNS}"; fi
[ "${FAILS}" -eq 0 ]
