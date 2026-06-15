# `gewgaw-collector`

A long-running daemon that records what the Pi's radios can see — nearby 2.4 GHz
**Wi-Fi APs** and **BLE devices** — into a local SQLite **presence model**, and
hosts the **single-radio arbiter** that lets `gewgaw-submit` borrow the radio for
uploads. Source: `meta-gewgaw/recipes-apps/gewgaw-collector/files/gewgaw-collector`.

Runs as `gewgaw-collector.service` (`Type=simple`, `Restart=on-failure`,
`After=bluetooth.service network.target`, auto-enabled). `ExecStartPre` creates
`/run/gewgaw` and `/var/lib/gewgaw`.

## Scan cycle

Every `SCAN_INTERVAL` (default 30 s):

1. Sample `NTPSynchronized` once → `clock_synced` for rows written this cycle.
2. **Wi-Fi** — *only if the arbiter grants it* (the radio may be leased to
   submit): `iw dev wlan0 scan`, parse, fold each AP into the presence model.
3. **BLE** — always (independent side of the combo chip): a timed
   `bluetoothctl --timeout <BLE_SCAN_SECONDS> scan on` window, then
   `bluetoothctl info <mac>` for each known device; keep only those reporting an
   RSSI *now* (this filters BlueZ's stale cache and yields real presence + RSSI).
4. **Reap** sessions whose last sighting is older than `SESSION_GAP`.

The loop self-corrects its sleep so a cycle takes ~`SCAN_INTERVAL` regardless of
scan duration.

### Wi-Fi parsing

`parse_iw_scan` walks `BSS` blocks and extracts BSSID, SSID, signal (dBm),
frequency → channel (2.4 GHz only: 2412→1 … 2472→13, 2484→14), and encryption,
derived as: `RSN`+SAE → `wpa3`, `RSN` → `wpa2`, `WPA` → `wpa`, `Privacy` → `wep`,
else `open`.

### BLE notes

- MAC randomization: phone/BLE client addresses rotate; AP BSSIDs are stable. The
  `addr_type` (public/random) is stored in `meta` so randomized churn can be
  filtered downstream.
- Managed-mode only: onboard `brcmfmac` monitor mode is unreliable, so the
  collector sees APs but not client probe traffic.

## Presence model (SQLite)

DB at `/var/lib/gewgaw/gewgaw.db` (WAL mode, `busy_timeout=5000` in both daemons).
Schema in `/usr/share/gewgaw/schema.sql`. The collector is the sole writer of
`devices`/`sessions`; submit reads them and writes `net_health`/`events`.

The core idea: **a row per *interval of presence*, not per scan.**

- **`devices`** — stable identity of a thing ever seen. `UNIQUE(kind, address)`
  where `kind ∈ {wifi_ap, ble}` and `address` is the BSSID/BLE MAC. `meta` is JSON
  (ssid, channel, freq, enc, ble_name, addr_type, …), merged non-destructively on
  each sighting.
- **`sessions`** — one contiguous interval a device was visible:
  `started_at`, `last_sight`, `ended_at` (NULL while present), `sighting_count`,
  `rssi_min/max/last`, `clock_synced`, `synced`.

On each observation (`record_observation`): upsert the device, then find its open
session. If `now - last_sight <= SESSION_GAP`, extend it (bump `last_sight`,
count, rssi aggregates); otherwise close any stale open session at its real
`last_sight` and open a new one. The reaper closes open sessions gone quiet past
the gap. Net effect: a device present for an hour is **one** growing session;
leaving and returning yields a **second** — a "seen / gone / back / gone" timeline
without a row per scan.

`SESSION_GAP` (default 300 s ≈ 10 missed 30 s scans) is the one tuning knob: too
short and a single missed scan splits a visit; too long and two visits merge.

`clock_synced` records whether NTP had synced when `started_at` was taken — the Pi
3 has **no RTC**, so early-boot rows may carry a skewed clock; the flag lets the
backend distinguish trustworthy timestamps. See [submit.md](submit.md) for how the
boot beacon re-establishes time.

### Other tables (written by submit)

- **`net_health`** — per-BSSID uplink reputation/blacklist; see
  [submit.md](submit.md#net_health-blacklist-9).
- **`events`** — telemetry (boot beacons) queued for upload; see
  [submit.md](submit.md#boot-beacon--the-events-queue).

### Retention

No auto-deletion — synced or not, rows are kept, relying on the `grow-rootfs`
headroom (GBs). There is no data loss across long offline periods, and no purge or
rotation policy.

## Radio arbiter

The Pi 3 has one 2.4 GHz radio, so the collector cannot scan while submit is
associated to an AP for an upload. The collector therefore hosts a unix-domain
socket server at `GEWGAW_SOCK` (`/run/gewgaw/arbiter.sock`, mode 0660). Line
protocol:

| Client → server | Effect | Reply |
| --- | --- | --- |
| `ACQUIRE <seconds>` | finish any in-flight scan, suspend Wi-Fi scanning, start a lease | `GRANTED` |
| `RELEASE` | resume Wi-Fi scanning | `OK` |
| `PING` | health/debug | `PONG <state>` (`idle`/`scanning`/`held`) |

Key properties:

- **One lease per connection.** The scan loop brackets each `iw` scan with
  `begin_wifi_scan()`/`end_wifi_scan()`; an `ACQUIRE` takes the lease and then
  *waits for any in-flight scan to drain* before returning `GRANTED`, so the radio
  is genuinely quiesced before submit retunes it. (A plain `flock` couldn't
  guarantee that active quiescence — only an explicit `GRANTED` does.)
- **Connection-bound watchdog.** The lease ends on `RELEASE`, on the
  per-connection lease **timeout**, or when the client **disconnects/crashes** —
  whichever comes first. The collector then auto-resumes scanning. No deadlock if
  submit dies mid-upload.
- **Lease clamp.** The requested duration is clamped to
  `[1, ARBITER_MAX_LEASE]` (`ARBITER_MAX_LEASE=600`, default 180) so a buggy
  client can never wedge scanning forever. The boot run's larger lease
  (`BOOT_LEASE_SECONDS`, 450) sits comfortably under the cap.
- **BLE keeps scanning** throughout a grant.

`gewgaw-submit` is the only client (`RadioLease` context manager). If the socket
is absent (collector not running), submit proceeds *without* a lease — there's
then no scanner to contend with.

## Configuration

`/etc/gewgaw/gewgaw.conf` (shell-style `KEY=VALUE`; the collector reads the keys
it cares about, defaults in brackets):

| Key | Default | Meaning |
| --- | --- | --- |
| `GEWGAW_DB` | `/var/lib/gewgaw/gewgaw.db` | SQLite path |
| `GEWGAW_SOCK` | `/run/gewgaw/arbiter.sock` | arbiter socket |
| `WIFI_IFACE` | `wlan0` | scan interface |
| `SCAN_INTERVAL` | `30` | seconds between Wi-Fi scans |
| `BLE_SCAN_SECONDS` | `10` | BLE discovery window per cycle |
| `SESSION_GAP` | `300` | seconds without a sighting before a session closes |

## Inspecting the DB

No `sqlite3` CLI ships — use the Python module over SSH, e.g. recent open Wi-Fi
sessions:

```sh
ssh -i target-root.pem root@192.168.55.5 'python3 -' <<'PY'
import sqlite3
c = sqlite3.connect("/var/lib/gewgaw/gewgaw.db"); c.row_factory = sqlite3.Row
for r in c.execute("SELECT d.kind,d.address,json_extract(d.meta,'$.ssid') ssid,"
                   "s.sighting_count,s.ended_at,s.synced FROM sessions s "
                   "JOIN devices d ON d.id=s.device_id ORDER BY s.id DESC LIMIT 10"):
    print(dict(r))
PY
```

Or `scp` the `.db` (plus `-wal`/`-shm`) to the host and open it locally.
</content>
