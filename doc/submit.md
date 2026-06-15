# `gewgaw-submit`

The opportunistic uploader. It finds a usable Wi-Fi uplink, borrows the radio from
the collector's arbiter, associates *transiently*, verifies real internet, and
batch-publishes new sightings + telemetry to AWS IoT Core — then drops the link so
the collector can resume scanning. Source:
`meta-gewgaw/recipes-apps/gewgaw-collector/files/gewgaw-submit`.

Two modes:

```sh
gewgaw-submit            # steady-state upload run (hourly timer)
gewgaw-submit boot       # boot beacon (first connect after a boot)
```

## systemd units

- **`gewgaw-submit.service`** — `Type=oneshot`, `After/Wants=gewgaw-collector`.
  Not enabled directly; driven by the timer.
- **`gewgaw-submit.timer`** — `OnUnitActiveSec=1h`, `Persistent=true`,
  auto-enabled. The hourly steady-state cadence.
- **`gewgaw-boot.service`** — `Type=oneshot`, once per boot,
  `After=gewgaw-collector.service network.target bluetooth.service`,
  `ExecStart=/usr/bin/gewgaw-submit boot`, auto-enabled.

## Steady-state run (`upload`)

1. **Anything to do?** Count closed unsynced sessions **and** unsynced events; if
   both are zero, exit.
2. **Candidate selection** — intersect what the collector sees *now* (open
   `wifi_ap` sessions with `last_sight` within `SESSION_GAP`) with config, drop any
   BSSID currently in `net_health` cooldown, and order:
   1. **known PSK** networks (from `networks.conf`) by `priority` then RSSI,
   2. **known open** networks,
   3. **discovered open** networks (only if `ALLOW_OPEN=1`) by RSSI.
3. **Acquire** the radio lease (`LEASE_SECONDS`, default 180) from the arbiter.
4. **Connect** — try candidates (capped at `MAX_ATTEMPTS`, default 4) until one
   yields real internet (see *Connection attempt* below). First good link wins.
5. **Flush** — on a good link, upload unsynced **events** first (small, low
   latency — boot beacons), then unsynced **sightings**.
6. **Teardown + release** — stop `wpa_supplicant@wlan0`, flush the address, delete
   the transient conf, `RELEASE` the lease (the `RadioLease` context manager and a
   `finally` guarantee teardown even on error).

## Connection attempt

Per candidate (`associate` → `connectivity_reason`):

1. Write a **transient single-network** `/etc/wpa_supplicant/wpa_supplicant-<iface>.conf`
   (created 0600 from the start so the PSK is never briefly world-readable; the
   directory is created if absent — important on a clean flash that never ran
   `setup-wlan.sh`). The block is **BSSID-pinned** (`bssid=…`) so the attempt
   targets exactly the AP the collector saw — essential for per-BSSID health
   (an open SSID like `xfinitywifi` exists at many BSSIDs with independent health).
2. `systemctl restart wpa_supplicant@<iface>`, wait up to `CONNECT_TIMEOUT` for
   `wpa_state=COMPLETED` (else fail reason `assoc`), then for a DHCP IPv4 from the
   shipped `80-gewgaw-wlan0.network` (else `dhcp`).
3. **Connectivity check**: `wget -S` the `HTTP_CHECK_URL`
   (`…/generate_204`) expecting **HTTP 204**. A 200/redirect = captive portal
   (`captive`); a timeout/DNS/no-route = `no_internet`. Only a real 204 counts as
   online.

Each attempt updates `net_health` (below). On success the winning candidate is
returned and the flush proceeds.

## `net_health` blacklist

Open hotspots are often captive-portal-only or simply dead; retrying them every
hour wastes the brief upload window. `net_health` tracks per-**BSSID** reputation
(precise — an SSID can be healthy at one AP and dead at another):

- **On failure** (`assoc`/`dhcp`/`captive`/`no_internet`): bump consecutive
  `fail_count`, store `last_fail_reason`/`last_attempt`, and arm `cooldown_until`
  with exponential backoff.
- **On success**: reset `fail_count = 0`, clear `cooldown_until`, stamp
  `last_success`.
- **Candidate filter**: BSSIDs with `now < cooldown_until` are dropped at
  selection time and skipped mid-run (so a freshly-cooled AP isn't retried within
  the same boot re-sweep).

Backoff ladders (`backoff_seconds`):

| Network kind | Ladder (by consecutive `fail_count`) |
| --- | --- |
| Discovered/known **open** | 15 min → 1 h → 6 h → 24 h → **7 d** (capped) |
| Open, last failure was **captive** | starts a rung higher (1 h → 6 h → 24 h → 7 d) — captive portals are reliably useless to us |
| Configured **PSK** | gentle: 5 min → 15 min → 30 min → 1 h (a known network failing is usually transient) |

Re-probe is **never permanent**: the 7-day cap means a long-dead AP is eventually
retried once, cheaply; a single fresh failure re-arms the long backoff. Reputation
is tracked per BSSID only — there is no SSID-level heuristic.

## Boot beacon & the `events` queue

The Pi 3 has no RTC, so establishing time and announcing presence at startup is
worth a bigger budget than a normal hourly run. `gewgaw-submit boot`:

1. **Record the intent first** — insert a `boot` event into `events` immediately
   (with `clock_synced` from `timedatectl` at that moment). Because *recording* is
   decoupled from *delivery*, a boot with no uplink this run is still reported on
   the next successful connect, stamped with its real time. Payload:
   `{ts, clock_synced, uptime, ip, ssid, image_version, kernel, pending_sightings,
   disk_free}` (`ip`/`ssid` filled once connected).
2. **Wait for candidates** — the collector just started; poll the DB up to
   `WAIT_FOR_SCAN` (default 60 s) for at least one visible, non-cooled AP.
3. **Acquire** a larger lease (`BOOT_LEASE_SECONDS`, default 450).
4. **Connect with a budget** — cycle the candidate list for up to
   `BOOT_CONNECT_BUDGET` (default 300 s), more forgiving than the steady-state
   `MAX_ATTEMPTS` cap, re-sweeping (with a short pause) so a momentarily-out-of-
   range AP gets another chance.
5. **Confirm NTP** — once online, wait up to `NTP_WAIT` (default 90 s) for
   `NTPSynchronized=yes` (`systemd-timesyncd` syncs automatically when online),
   then **re-stamp** the boot event with the corrected clock + the actual ip/ssid.
6. **Flush** — events to `…/status`, then sightings to `…/sightings`.
7. **Teardown + release.**

If the budget expires without a connection, the run exits cleanly and the queued
boot event stays `synced=0` for the next (hourly) run — delivered later with its
original timestamp. The `events` table (`ts`, `type`, `clock_synced`, `payload`
JSON, `synced`) is general-purpose telemetry; boot beacons are the events it
carries.

`BOOT_LEASE_SECONDS` (450) must exceed worst-case work
(`BOOT_CONNECT_BUDGET` 300 + `NTP_WAIT` 90 + flush) so the arbiter watchdog
doesn't auto-resume scanning mid-flush; it stays under `ARBITER_MAX_LEASE` (600)
so it's granted in full.

## Upload format

- **Sightings**: closed unsynced sessions only (`ended_at NOT NULL AND
  synced = 0`); open sessions upload once they close. Each row → JSON:
  `{kind, address, ssid|name, channel, enc, started_at, ended_at,
  sighting_count, rssi_min, rssi_max, rssi_last}`.
- **Events**: each unsynced row → its stored payload plus `type`/`ts`/
  `clock_synced`.
- Batched into chunks of `SUBMIT_BATCH` (default 200) as a JSON array, published
  one chunk per `aws-iot-mqtt pub` (keeps each well under AWS IoT's 128 KB).
- **Sync semantics**: a chunk's rows are marked `synced = 1` **only after** its
  `pub` exits 0. A failure (bad certs, clock skew, dropped link) leaves the
  remaining rows unsynced for the next run — idempotent, survives disconnection,
  and accumulates safely while offline.

## Clock handling (no RTC)

The Pi 3 B v1.2 has no RTC, so the clock is wrong until NTP corrects it. TLS to
AWS IoT **fails** if the device clock is behind the device cert's `notBefore`
(observed as `aws-iot-mqtt` exiting non-zero, e.g. rc=14). Mitigations:

- `systemd-timesyncd` persists the last-known time across reboots
  (`/var/lib/systemd/timesync/clock`) and re-syncs as soon as the device is
  online; the boot beacon explicitly **waits for `NTPSynchronized=yes`** before
  treating its timestamp as trustworthy.
- Every row carries a `clock_synced` flag, so skewed early-boot rows are
  distinguishable downstream.
- Decoupled delivery means a boot recorded with a bad clock is still delivered
  later; its re-stamped copy carries the corrected time.

## Configuration

`/etc/gewgaw/gewgaw.conf` keys used by submit (defaults in brackets):

| Key | Default | Meaning |
| --- | --- | --- |
| `WIFI_IFACE` | `wlan0` | uplink interface |
| `KNOWN_NETWORKS` | `/etc/gewgaw/networks.conf` | known-network list (see [wifi.md](wifi.md)) |
| `ALLOW_OPEN` | `1` | also try discovered open APs |
| `MAX_ATTEMPTS` | `4` | candidate APs per steady-state run |
| `LEASE_SECONDS` | `180` | steady-state radio lease |
| `CONNECT_TIMEOUT` | `45` | per-AP assoc+DHCP timeout |
| `HTTP_CHECK_URL` | gstatic `/generate_204` | connectivity check |
| `SUBMIT_BATCH` | `200` | rows per publish chunk |
| `WAIT_FOR_SCAN` | `60` | boot: max wait for the first scan |
| `BOOT_CONNECT_BUDGET` | `300` | boot: seconds to keep trying to get online |
| `BOOT_LEASE_SECONDS` | `450` | boot: radio lease |
| `NTP_WAIT` | `90` | boot: max wait for `NTPSynchronized=yes` |

(`GEWGAW_DB`, `GEWGAW_SOCK`, `SESSION_GAP` are shared with the collector.) The
topic base is derived from `aws-iot.conf`'s `AWS_IOT_TOPIC`; see
[aws-iot.md](aws-iot.md#topics).

## Operating modes recap

For uploads to happen the device needs at least one reachable network. In
**normal/opportunistic** mode, register known networks with `add-network.sh`
and/or rely on discovered open APs (`ALLOW_OPEN=1`); do **not** run
`setup-wlan.sh`, which pins the radio permanently and starves the cycle. See
[wifi.md](wifi.md) for the full mode comparison.
</content>
