# rnsd installers

Installs the [Reticulum Network Stack](https://markqvist.github.io/Reticulum/) daemon (`rnsd`) on Debian/Ubuntu or Alpine, configured as a boot-enabled, auto-restarting service, and optionally the Analog notifier stack alongside it.

## Recommended: unified installer

Examples below use these placeholder values — substitute your own:

| Placeholder | Example | Meaning |
|---|---|---|
| server | `node.example.com`, user `admin` | the VM running rnsd |
| Team ID | `A1B2C3D4E5` | Apple Developer team (10 chars, top-right of the portal) |
| Key ID | `ABC123DEFG` (sandbox), `XYZ789UVWX` (production) | from the `.p8` file name `AuthKey_<KEYID>.p8` |
| LXMF hash | `3f2a9c1e7b6d4a5c8e0f1b2d3c4a5e6f` | a device's LXMF delivery destination (32 hex chars) |
| APNs token | `d9a1…64 hex chars…7c` | device token the iOS app receives from APNs |

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
  4) Repair / update existing install (permissions, ACL, code — keeps configs + keys)
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
# RNS_ENV=apt|apk               RNS_INSTALL=full|rnsd|notifier|fix
# (legacy: RNS_NOTIFIER=yes|no  → yes=full, no=rnsd)
curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh | RNS_ENV=apt RNS_INSTALL=full sudo -E bash

# Examples:
#   fresh Debian VM, everything:       RNS_ENV=apt RNS_INSTALL=full
#   Alpine, rnsd only:                 RNS_ENV=apk RNS_INSTALL=rnsd
#   add the notifier to an rnsd host:  RNS_ENV=apt RNS_INSTALL=notifier
#   repair after an upgrade:           RNS_ENV=apt RNS_INSTALL=fix
```

Or on the server itself, non-interactively from a downloaded copy:
```
ssh admin@node.example.com
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh
sudo RNS_ENV=apt RNS_INSTALL=full sh install.sh
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

**Steps.** The key must never travel with the installer (`curl | bash`), so this is done from a downloaded copy of `install.sh`:

```
# 1. Get the key. Apple Developer → Certificates, Identifiers & Profiles → Keys → "+" →
#    enable Apple Push Notifications service (APNs) → Download. You get AuthKey_<KEYID>.p8
#    (the Key ID is in the file name); note your Team ID (top-right of the portal).
#    Back it up off-server now — Apple never lets you download it again.

# 2. On your machine: copy the key to the server over SSH.
scp AuthKey_<KEYID>.p8 <user>@<server>:/tmp/

# 3. On the server: get the installer and install the key for the environment it serves.
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh
sudo sh install.sh --install-key /tmp/AuthKey_<KEYID>.p8 \
     --team-id <TEAMID> --bundle-id app.analog.dev --env sandbox

#    Repeat with the other key/environment if you serve both:
sudo sh install.sh --install-key /tmp/AuthKey_<KEYID2>.p8 \
     --team-id <TEAMID> --bundle-id app.analog.app --env production

# 4. Remove the uploaded copies (Alpine/busybox has no shred: rm -f).
shred -u /tmp/AuthKey_*.p8

# 5. Verify.
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/checkHealth.sh
sudo sh checkHealth.sh        # expect: [apns.sandbox] configured — … (key: encrypted credential)
```

Worked example — both environments from one node, Team ID `A1B2C3D4E5`, keys `ABC123DEFG` (dev) and `XYZ789UVWX` (prod):

```
# on your Mac, in the folder holding the keys
scp AuthKey_ABC123DEFG.p8 AuthKey_XYZ789UVWX.p8 admin@node.example.com:/tmp/

# on the server
ssh admin@node.example.com
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh
sudo sh install.sh --install-key /tmp/AuthKey_ABC123DEFG.p8 --team-id A1B2C3D4E5 --bundle-id app.analog.dev --env sandbox
sudo sh install.sh --install-key /tmp/AuthKey_XYZ789UVWX.p8 --team-id A1B2C3D4E5 --bundle-id app.analog.app --env production
shred -u /tmp/AuthKey_ABC123DEFG.p8 /tmp/AuthKey_XYZ789UVWX.p8
```

The resulting `[apns.*]` blocks in `/etc/analog/notifier.conf`:

```ini
[apns.production]
team_id = A1B2C3D4E5
key_id = XYZ789UVWX
bundle_id = app.analog.app
key_path = /etc/analog/apns_production.p8      # ignored when the encrypted credential exists
host = api.push.apple.com

[apns.sandbox]
team_id = A1B2C3D4E5
key_id = ABC123DEFG
bundle_id = app.analog.dev
key_path = /etc/analog/apns_sandbox.p8
host = api.development.push.apple.com
```

To rotate the sandbox key later: create a new key in the portal, then re-run `--install-key` with the new file and `--env sandbox`; revoke the old key in the portal once `checkHealth.sh` is green.

What `--install-key` does: derives the Key ID from the file name (override with `--key-id`), stores the key so that only the `analog-notifier` service can read it (see below), fills the matching `[apns.<env>]` block, and restarts the notifier. `--env` can be omitted when `--bundle-id` is given (`*.dev` → sandbox, otherwise production). Re-run it to rotate a key. Check the result with `journalctl -u analog-notifier -f` (Alpine: `tail -f /var/log/analog-notifier/notifier.log`) — while anything is missing it logs exactly which field of which environment.

Keep the `.p8` files backed up **off** the server: Apple does not let you re-download a key. Losing one means creating a new key and re-running `--install-key`.

### Device registration

Devices register themselves over Reticulum — no HTTP, no open port. The notifier announces its `analog.notifier.register` destination every 5 minutes (with the propagation node hash it serves in the announce's `app_data`); the app enters that destination in *Settings → Network settings*, resolves a path, opens a link, **identifies with its LXMF identity**, and sends one `/register` request:

```
{"apns_token": "<64 hex>", "bundle_id": "app.analog.dev"}     → {"ok": true, "changed": true}
{"action": "unregister"}                                       → {"ok": true, "changed": true}
```

The notifier derives the device's LXMF hash from the identity proven on the link (`hash_from_name_and_identity("lxmf.delivery", …)`) — a device can only ever bind a token to an address it owns. Unidentified links get `{"error": "unidentified"}` and nothing is stored; other errors are `bad token`, `bad bundle`, `bad request`. The `bundle_id` selects the APNs environment (`app.analog.app` → production, `app.analog.dev` → sandbox). Watch it happen with `journalctl -u analog-notifier -f`:

```
[analog-notifier] announced fedcba9876543210fedcba9876543210
[analog-notifier] registered a7c3e9f1… (sandbox, changed=True)
```

The notifier reaches the network as a **client of rnsd's shared instance** (its own tiny RNS config in `/var/lib/analog-notifier/rns`, same `instance_name` as rnsd); if rnsd is down it exits and systemd restarts it until rnsd is back. `registration = no` in `notifier.conf` turns the listener off.

One detail worth knowing: RNS authenticates a client's RPC calls to the shared instance with `rpc_key`, which by default is derived from rnsd's transport private key — exactly the file the notifier must not read. The installer therefore puts an explicit, generated `rpc_key` in **both** rnsd's config and the notifier's RNS config (`--fix` adds it to existing nodes and restarts rnsd + lxmd once). Without it, link identification fails inside RNS (`digest sent was rejected`) and every registration is refused as `unidentified`. `checkHealth.sh` verifies the two keys match. The RPC key only grants status/blackhole queries on rnsd, not its identity.

**Token registrations** land in `/var/lib/analog-notifier/tokens.json` (you can also edit it by hand):

```json
{
  "<lxmf_destination_hash>": "<apns_token>",
  "<lxmf_destination_hash>": {"token": "<apns_token>", "env": "sandbox"}
}
```

A plain string means production. A token whose environment is not configured is skipped with a log line; the message still waits at the node.

Example — one hand-added App Store user and one device that registered itself:

```json
{
  "3f2a9c1e7b6d4a5c8e0f1b2d3c4a5e6f": "d9a1f0c4e2b7a8d3c5f6e1b2a4c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5",
  "a7c3e9f1b5d2c8e4f6a0b1c2d3e4f5a6": {"token": "7c2e4a6b8d0f1a3c5e7b9d1f2a4c6e8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c",
                                       "env": "sandbox", "bundle_id": "app.analog.dev", "updated": 1787600000}
}
```

Validate, and (optionally) fire a test ping without waiting for real mail:

```
python3 -m json.tool /var/lib/analog-notifier/tokens.json
sudo -u analog-notifier python3 /opt/analog-notifier/analog_notifier.py --trigger --recipient-hash a7c3e9f1b5d2c8e4f6a0b1c2d3e4f5a6
sudo journalctl -u analog-notifier -n 5      # "APNs ping sent for a7c3e9f1… (sandbox)"
```

No restart is needed after a manual edit — the daemon re-reads the file on every ping.

### How the key is protected on the host

The `.p8` is a team-wide, non-expiring signing key — whoever holds it can push to every user of every app under the Apple team. The installer treats it accordingly:

| Layer | What the installer does |
|---|---|
| Registration auth | A device's LXMF hash is derived from the identity proven on the Reticulum link, never taken from the request — nobody can bind a token to someone else's address. |
| Own identity | The notifier has its own RNS identity (`/var/lib/analog-notifier/identity`, `0600`), separate from rnsd's and lxmd's; its registration address `analog.notifier.register` derives from it. |
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

Example output (healthy node, no devices registered yet):

```
rnsd (Reticulum)
  PASS  rnsd is running and enabled at boot
  PASS  TCPServerInterface listening on TCP 4242
  WARN  rnstatus: 7/10 interfaces Up
          [ up ] TCPServerInterface[Local TCP Server/0.0.0.0:4242]  (Clients: 16, rate 10.00 Mbps)
          [down] TCPInterface[Beleth RNS Hub/rns.beleth.net:4242]  (rate 10.00 Mbps)
          …
  PASS  identity files are not world-readable

lxmd (propagation node)
  PASS  Propagation Node running on <0123456789abcdef0123456789abcdef>, uptime is 14m and 38.89s
          Messagestore contains 2188 messages, 2.76 MB (0.55% utilised of 500.00 MB)
  PASS  message store: 2188 message(s) in /var/lib/reticulum/.lxmd/storage/lxmf/messagestore

analog-notifier
  PASS  analog-notifier can read the message store (ACL ok)
  PASS  propagation node identifier (select this node in the Analog app): 0123456789abcdef0123456789abcdef
  PASS  notifier identity present; registration destination (analog.notifier.register): fedcba9876543210fedcba9876543210
  PASS  registration destination is announced (present in rnsd's path table)
  PASS  notifier announces propagation node 0123456789abcdef0123456789abcdef
  PASS  [apns.sandbox] configured — bundle app.analog.dev, host api.development.push.apple.com (key: encrypted credential)
  WARN  token DB valid but empty — no device will be pinged yet

Propagation node for the Analog app   : 0123456789abcdef0123456789abcdef
Notifier registration destination     : fedcba9876543210fedcba9876543210  (analog.notifier.register)
3 warning(s), no failures.
```

Two identifiers are printed at the end:

- **Propagation node** — the hash of lxmd's `lxmf.propagation` destination; what a user enters in the Analog app to use this node for store-and-forward. Derived from `/var/lib/reticulum/.lxmd/identity`.
- **Notifier registration destination** — the hash of `analog.notifier.register`, derived from the notifier's own RNS identity at `/var/lib/analog-notifier/identity`. This is what a user enters in the app's *Network settings* so the device can register its APNs token. Generated at install (`--fix` adds it to older installs), announced every 5 minutes, never rotated automatically.

Both addresses are stable as long as their identity files are kept. **Back up both identity files**: replacing one changes the address every app has stored. Print them at any time with:

```
sudo -u reticulum lxmd --status --config /var/lib/reticulum/.lxmd --rnsconfig /var/lib/reticulum/.reticulum | head -2
sudo -u analog-notifier python3 /opt/analog-notifier/analog_notifier.py --identity
```

Walks every layer and prints one `PASS` / `WARN` / `FAIL` line per item: clock sync and disk; rnsd running, listening on its TCP port, interfaces up (`rnstatus`), identity files not world-readable; lxmd running with peers and store size (`lxmd --status`), recent `[Error]` lines; the notifier's user, its read-only ACL on the store (and that it *cannot* read rnsd's dir), each `[apns.<env>]` profile's completeness and key storage, the token DB, Python deps, and TLS reachability of both APNs hosts. Exit code is non-zero if anything `FAIL`ed, so it can be cron'd or used in monitoring.

### Repair / update an existing node

```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/install.sh
sudo sh install.sh --fix        # or: menu option 4, or RNS_INSTALL=fix
```

Non-interactive. Brings a node installed by an earlier version up to the current layout **without touching** the lxmd config, existing `notifier.conf` values or the APNs keys: strips world-read access from `/var/lib/reticulum`, adds `UMask=0027` to the rnsd/lxmd units, migrates a stale `messagestore` path, re-applies the notifier's read-only ACL, fixes ownership of keys/state, and refreshes the notifier code + service definition (the key drop-ins are preserved). The one thing it does add to the RNS config is the relay-wake wiring: `enable_remote_management = Yes` plus the notifier's identity in `remote_management_allowed` (rnsd and lxmd restart once when that changes), and `transport_identity` in `notifier.conf`. Run `checkHealth.sh` afterwards; if it reports something fixable, `--fix` is the intended remedy.

Log readers, all read-only: `readLogs.sh` (both daemons merged in time order, each line marked `RNSD` or `NOTIFIER` — the one to follow a send from a phone end to end), `rnsdLog.sh` (rnsd: interface events, errors, and at loglevel ≥ 5 announces/paths/links), `notifierLog.sh` (registrations, pushes, relay wakes, refusals), `listTokens.sh` (who is registered). Each takes `-f`, `--only <group>`, `--summary` and a text filter; `--help` lists them.

Operator scripts, each root-only and with `--help`: `reticulumStatus.sh` (rnstatus plus `lxmd --status` as the service user; `--paths` for the path table), `restartRnsd.sh` (the chain in order: rnsd, lxmd, notifier; verifies the 4242 listener), `restartLxmd.sh` (lxmd and the notifier, then prints the node's own status), `clearLxmd.sh` (drops rnsd's persisted path table and tunnels and lxmd's peer list so the network is relearned; `--messages` also empties the message store, asking unless `--yes`; restarts the chain), `editRnsConfig.sh` / `editLxmdConfig.sh` (backup, `$EDITOR`, restart on change), `changeRnsPort.sh`.

The installer puts all of these, plus `checkHealth.sh`, in `/opt/rnsd-tools` and symlinks them into `/usr/local/sbin` at the end of every install and of `--fix` — copied from beside `install.sh` when run from a checkout, fetched from this repo under `curl | sh`. So after `--fix` the node's scripts match its installer and `readLogs.sh -f` works from any directory; the `curl -fsSLO` lines elsewhere in this README remain a fine way to grab a single script.

### Change the rnsd TCP port

```
sudo sh changeRnsPort.sh          # prompts, default 4242
sudo sh changeRnsPort.sh 4242
```

Example — move from the old default 7822 to 4242 and check:
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/changeRnsPort.sh
sudo sh changeRnsPort.sh 4242
ss -tlnp | grep rnsd              # 0.0.0.0:4242
```
Peers that connect to you by address then need `node.example.com:4242` in their `TCPClientInterface`.

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
