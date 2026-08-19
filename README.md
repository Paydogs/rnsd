Direct install on Debian
```
curl -fsSL https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apt.sh | sudo bash
```

Pre-verifiable version
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apt.sh
less installRnsd_apt.sh
sudo bash installRnsd_apt.sh
```

Direct install on Alpine
```
wget -qO- https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apk.sh | sh
```

Pre-verifiable version
```
curl -fsSLO https://raw.githubusercontent.com/Paydogs/rnsd/master/installRnsd_apk.sh
cat installRnsd_apk.sh
chmod +x installRnsd_apk.sh
./installRnsd_apk.sh
```

---

## Analog notifier (companion installers)

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
3. Fill `team_id`, `key_id`, `bundle_id`, `key_path` in `/etc/analog/notifier.conf`
   (use `host = api.development.push.apple.com` for sandbox builds).
4. Restart `analog-notifier` and `lxmd`.
