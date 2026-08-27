# rnsd installers

Installs the [Reticulum Network Stack](https://markqvist.github.io/Reticulum/) daemon (`rnsd`) on Debian/Ubuntu or Alpine, configured as a boot-enabled, auto-restarting service, and optionally the Analog notifier stack alongside it.

## Recommended: unified installer

`install.sh` is the designated entry point. It auto-detects your environment (Debian/Ubuntu → apt/systemd, Alpine → apk/OpenRC), then asks what to install: the full stack, rnsd only, or — if rnsd is already installed — just the Analog notifier.

```
Select the environment:
  1) APT (Debian/Ubuntu, systemd)   [detected]
  2) APK (Alpine, OpenRC)
Enter choice [1]:

Select what to install:
  1) rnsd + Analog notifier   (full stack)
  2) rnsd only
  3) Analog notifier only    (requires rnsd already installed)   [rnsd detected]
Enter choice [3]:
```

The install prompt defaults to **full** when rnsd is not yet installed, and to **notifier only** when rnsd is already detected — so re-running the script after a first install just adds the notifier without reinstalling rnsd.

Direct install:
```
curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh | sudo bash
```

Pre-verifiable version:
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh
less install.sh
sudo bash install.sh
```

Non-interactive (for `curl | sh` / CI — skips the prompts):
```
RNS_ENV=apt RNS_INSTALL=notifier curl -fsSL .../install.sh | sudo bash
# RNS_ENV=apt|apk               RNS_INSTALL=full|rnsd|notifier
# (legacy: RNS_NOTIFIER=yes|no  → yes=full, no=rnsd)
```

Each install runs in clearly marked phases (6 for rnsd, 6 for the notifier) printed live as it goes; the same phase structure is used on both OSes.

### Installing the APNs key(s)

The repo never contains a `.p8`; the key is uploaded by hand after the install. The notifier stays dormant until at least one environment is configured.

**Why two environments.** An APNs device token only works against the environment the app build was signed for:

| Build | Bundle ID | APNs environment / host |
|---|---|---|
| App Store / TestFlight | `app.analog.app` | `production` → `api.push.apple.com` |
| Xcode development build | `app.analog.dev` | `sandbox` → `api.development.push.apple.com` |

`notifier.conf` therefore has one `[apns.production]` and one `[apns.sandbox]` profile, each with its own key. A single node can serve both; configure whichever you need. (An APNs auth key itself is not environment-specific — the same `.p8` works for both hosts — but using separate keys per environment is fine and keeps the blast radius smaller.)

**Steps, once per environment.** Do this from a local copy of `install.sh`, never through `curl | bash`:

```
# 1. Apple Developer → Certificates, Identifiers & Profiles → Keys → "+" →
#    enable Apple Push Notifications service (APNs) → download AuthKey_<KEYID>.p8.
#    Note the Key ID (in the file name) and your Team ID (top-right of the portal).

# 2. Copy the key to the server over SSH.
scp AuthKey_<KEYID>.p8 server:/tmp/

# 3. On the server, store it for the environment it serves.
sudo sh install.sh --install-key /tmp/AuthKey_<KEYID>.p8 \
     --team-id <TEAMID> --bundle-id app.analog.app --env production

sudo sh install.sh --install-key /tmp/AuthKey_<KEYID2>.p8 \
     --team-id <TEAMID> --bundle-id app.analog.dev --env sandbox

# 4. Remove the uploaded copies (Alpine/busybox: rm -f).
shred -u /tmp/AuthKey_<KEYID>.p8 /tmp/AuthKey_<KEYID2>.p8
```

What `--install-key` does: derives the Key ID from the file name (override with `--key-id`), stores the key so that only the `analog-notifier` service can read it (see below), fills the matching `[apns.<env>]` block, and restarts the notifier. `--env` can be omitted when `--bundle-id` is given (`*.dev` → sandbox, otherwise production). Re-run it to rotate a key. Check the result with `journalctl -u analog-notifier -f` (Alpine: `tail -f /var/log/analog-notifier/notifier.log`) — while anything is missing it logs exactly which field of which environment.

Keep the `.p8` files backed up **off** the server: Apple does not let you re-download a key. Losing one means creating a new key and re-running `--install-key`.

**Token registrations** in `/var/lib/analog-notifier/tokens.json` record the environment of each device (until the RNS registration listener exists, this file is edited by hand):

```json
{
  "<lxmf_destination_hash>": "<apns_token>",
  "<lxmf_destination_hash>": {"token": "<apns_token>", "env": "sandbox"}
}
```

A plain string means production. A token whose environment is not configured is skipped with a log line; the message still waits at the node.

### How the key is protected on the host

The `.p8` is a team-wide, non-expiring signing key — whoever holds it can push to every user of every app under the Apple team. The installer treats it accordingly:

| Layer | What the installer does |
|---|---|
| Separate user | The notifier runs as `analog-notifier`. `rnsd` and `lxmd` — the internet-facing daemons, user `reticulum` — **cannot read the key**. |
| No code inside lxmd | The notifier is not an `on_inbound` hook (that hook only fires for lxmd's own inbox anyway). It watches `~reticulum/.lxmd/storage/lxmf/messagestore` through a **read-only POSIX ACL** and reads only the 16-byte recipient-hash header lxmd itself writes at the front of each stored (ciphertext) message. It has no access to rnsd's or lxmd's identity files. |
| Key at rest | On systemd ≥ 250 (Debian 12+, Ubuntu 24.04) each key is stored as a **`systemd-creds` encrypted credential** (`/etc/analog/apns_p8_<env>.cred`, root-only) bound to the host (TPM2 when present) and decrypted only into the service's private credentials mount. Elsewhere (Alpine, older systemd) it is `/etc/analog/apns_<env>.p8`, mode `0400`, owned by `analog-notifier`. |
| Sandbox | The notifier unit runs with `ProtectSystem=strict`, no capabilities, `NoNewPrivileges`, a `@system-service` syscall filter, and IP/unix sockets only. |
| JWT reuse | The provider JWT is cached for 50 min (Apple rejects tokens refreshed more often than every 20 min). |

Things only you can do: keep one APNs key per server so a compromised box means revoking one key; keep the `.p8` backed up off the host; put full-disk encryption on the VM; and if third parties will ever run propagation nodes, put the key behind a relay you operate rather than handing it out.

`tokens.json` (`{lxmf_hash: apns_token}`) is low-sensitivity on its own — a device token is only useful together with the key. Until the RNS registration listener is implemented it is filled by hand.

## Operating a node

### Health check

```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/checkHealth.sh
sudo sh checkHealth.sh
```

Walks every layer and prints one `PASS` / `WARN` / `FAIL` line per item: clock sync and disk; rnsd running, listening on its TCP port, interfaces up (`rnstatus`), identity files not world-readable; lxmd running with peers and store size (`lxmd --status`), recent `[Error]` lines; the notifier's user, its read-only ACL on the store (and that it *cannot* read rnsd's dir), each `[apns.<env>]` profile's completeness and key storage, the token DB, Python deps, and TLS reachability of both APNs hosts. Exit code is non-zero if anything `FAIL`ed, so it can be cron'd or used in monitoring.

### Change the rnsd TCP port

```
sudo sh changeRnsPort.sh          # prompts, default 4242
sudo sh changeRnsPort.sh 4242
```

Checks the port is free, backs up and rewrites `listen_port` for the `TCPServerInterface`, restarts rnsd and verifies the listener, and swaps the ufw rule if ufw is active. lxmd and the notifier reconnect on their own.

### Useful commands

```
sudo -u reticulum rnstatus --config /var/lib/reticulum/.reticulum
sudo -u reticulum lxmd --status --config /var/lib/reticulum/.lxmd --rnsconfig /var/lib/reticulum/.reticulum
tail -f /var/lib/reticulum/.lxmd/logfile          # lxmd --service logs to a file, not the journal
journalctl -u analog-notifier -f
```

---

## Fallback: per-OS installers

The original single-purpose scripts remain available if you prefer them or need to run only one piece. The unified installer above is otherwise preferred.

### rnsd only

Direct install on Debian/Ubuntu:
```
curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apt.sh | sudo bash
```

Pre-verifiable version:
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apt.sh
less installRnsd_apt.sh
sudo bash installRnsd_apt.sh
```

Direct install on Alpine:
```
wget -qO- https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apk.sh | sh
```

Pre-verifiable version:
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apk.sh
cat installRnsd_apk.sh
chmod +x installRnsd_apk.sh
./installRnsd_apk.sh
```

### Analog notifier (companion installers — legacy layout)

> These two scripts predate the hardened layout in `install.sh`: they run the notifier as the `reticulum` user with the key group-readable, and wire an `on_inbound` hook that does not fire for propagation traffic. Prefer `install.sh`; they are kept only for reference.

Optional companion to the rnsd installers above. Adds the two server-side pieces
the iOS background wake-up design needs alongside a running rnsd:

- **`lxmd`** — the LXMF Propagation Node daemon (store-and-forward). Holds
  offline messages until the recipient's app acks. This is the substrate; it
  works on its own and does **not** depend on APNs.
- **`analog-notifier`** — the distributed APNs wake-up service. Receives
  `{lxmf_hash, apns_token}` bindings from apps at pairing (over RNS), and pings
  APNs (`mutable-content: 1`) via lxmd's `--on-inbound` hook when mail is queued
  for a recipient. Coalesced (one ping per recipient per window). The notifier
  never sees message plaintext — only the recipient hash and, in the full
  design, an E2E ciphertext envelope.

> **Status: skeleton.** The ops scaffolding (service units, config, paths,
> coalescing, APNs `.p8`/JWT send, `on_inbound` wiring) is real; the
> `on_inbound` contract, encrypted-envelope/NSE payload, and registration-packet
> authentication are TODO (marked in `analog_notifier.py`). `lxmd` starts for
> real on install; the notifier installs dormant and activates only once you
> drop the APNs `.p8` and fill `/etc/analog/notifier.conf`.
>
> **Requires** rnsd to be installed first (shares its `reticulum` user and RNS
> instance). Design memo: `Analog-swift/Documentation/Future/iOS-APNs-Wake-Up-Ping.html`.

Install on Debian/Ubuntu (after `installRnsd_apt.sh`):
```
curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/installAnalogNotifier_apt.sh | sudo bash
```

Install on Alpine (after `installRnsd_apk.sh`):
```
wget -qO- https://raw.githubusercontent.com/Paydogs/rnsd/master/installAnalogNotifier_apk.sh | sh
```

Activate the notifier after install:
1. Apple Developer → Keys → APNs Auth Key: download the `.p8`, note Key ID + Team ID.
2. Copy it to `/etc/analog/` (mode `640`, `root:reticulum`).
3. Fill `team_id`, `key_id`, `bundle_id`, `key_path` in `/etc/analog/notifier.conf`.
   `bundle_id` is `app.analog.app` (production) or `app.analog.dev` (dev); pair the
   production bundle with `host = api.push.apple.com`, the dev bundle with
   `host = api.development.push.apple.com`.
4. Restart `analog-notifier` and `lxmd`.
