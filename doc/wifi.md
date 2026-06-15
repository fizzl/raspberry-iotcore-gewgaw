# Wi-Fi (`wlan0`) configuration

The Pi 3 has a **single 2.4 GHz radio**. The image already ships everything to
use it — `kernel-module-brcmfmac`, the BCM43430 firmware, `wpa-supplicant`, and
`iw` (all via the `raspberrypi3` machine). Only runtime configuration is missing,
and there are **two mutually-exclusive ways** to provide it.

## Two modes, pick one

| | **Dev mode** (`setup-wlan.sh`) | **Normal/opportunistic mode** (`add-network.sh`) |
| --- | --- | --- |
| Purpose | Continuous internet for development | Production travel: scan most of the time, upload in short windows |
| What it writes | persistent `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` + `25-wlan0.network` | a `network={}` block in `/etc/gewgaw/networks.conf` |
| Association | **permanent** — `wpa_supplicant@wlan0` enabled and connected | **transient** — `gewgaw-submit` connects only during its radio-lease window, then drops |
| Effect on collector | radio stays associated → opportunistic cycle **can't scan/upload** | collector scans whenever submit isn't holding the lease |

Because the radio is shared (see [collector.md](collector.md) for the arbiter),
you cannot have both. Dev mode is for when you just want the device online; normal
mode is the actual product behavior.

## Dev mode — `setup-wlan.sh`

```sh
./setup-wlan.sh "MySSID"        # prompts for the passphrase (no echo)
./setup-wlan.sh "MySSID" ""     # open network
WIFI_PSK=… ./setup-wlan.sh MySSID   # PSK via env instead of prompt
```

It SSHes in over `eth0` and, on the device:

- hashes the PSK with `wpa_passphrase` (the **plaintext passphrase is never
  stored** on the target — only the hash) and writes a persistent
  `wpa_supplicant-wlan0.conf` with `country=$WIFI_COUNTRY` (default `FI`);
- writes `25-wlan0.network` (DHCP, `RouteMetric=600` so `eth0` stays preferred if
  both are up — though `eth0` has no gateway, so wlan0 is the real default route);
- enables + starts `wpa_supplicant@wlan0`, `rfkill unblock wifi`, restarts
  networkd, waits for an IPv4, and pings `1.1.1.1` via wlan0 to confirm internet.

`WIFI_COUNTRY` (default `FI`) sets the regdomain so channels 12/13 are usable —
see the caveat below. Re-run after each flash.

## Normal mode — `add-network.sh`

Registers a known network for the opportunistic uplink without connecting
anything:

```sh
./add-network.sh "HomeNet"            # prompts for PSK; default priority 50
./add-network.sh "CafeOpen" "" 10     # open network, priority 10
./add-network.sh "HomeNet" "" 100     # update HomeNet (dedup by SSID) to prio 100
```

On the device it appends/updates a `network={}` block in
`/etc/gewgaw/networks.conf` (mode 0600), PSK hashed with `wpa_passphrase`,
de-duplicated by SSID (re-run to edit in place). Higher `priority` is preferred
when several known APs are visible. **Nothing is enabled or connected** —
`gewgaw-submit` parses this file each run, associates *transiently* to a visible
known (or, if `ALLOW_OPEN=1`, discovered-open) AP during its radio lease, uploads,
and drops the link. See [submit.md](submit.md) for selection + the `net_health`
blacklist.

`networks.conf` is `wpa_supplicant`-native and gitignored; only
`networks.conf.sample` is tracked. Example:

```
network={
    ssid="HomeNet"
    psk=<64-hex-hash>
    priority=100
}
network={
    ssid="CafeOpen"
    key_mgmt=NONE
    priority=10
}
```

## The opportunistic networkd unit

`80-gewgaw-wlan0.network` (shipped in the image) provides fallback DHCP for
`wlan0` with `RouteMetric=600`. The `80-` prefix is a lower priority than a
dev-pushed `25-wlan0.network`, so dev mode wins if both exist.

## Switching from dev back to normal

If a device was put in dev mode, undo it before relying on the opportunistic
cycle:

```sh
ssh -i target-root.pem root@192.168.55.5 '
  rm -f /etc/wpa_supplicant/wpa_supplicant-wlan0.conf \
        /etc/systemd/network/25-wlan0.network &&
  systemctl disable --now wpa_supplicant@wlan0'
```

Then register networks with `add-network.sh`.

## Regdomain (2.4 GHz channels 12/13)

The device's wireless regdomain defaults to `country 00` (world), under which only
channels **1–11** are usable; APs on 12/13 are invisible to both scanning and
association. `setup-wlan.sh` sets `country=FI` in its persistent conf, but the
**transient** conf that `gewgaw-submit` writes per attempt does **not** set a
country — so opportunistic uploads use ch 1–11. To use 12/13 for the uplink, set
the regdomain another way, e.g. `iw reg set <CC>` at boot.
</content>
