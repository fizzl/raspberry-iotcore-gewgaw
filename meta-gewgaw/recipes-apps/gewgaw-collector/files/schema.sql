-- gewgaw sighting + telemetry store. See scan_and_submit_daemons_design.md.
--
-- Presence model: a `devices` row is the stable identity of a thing ever seen;
-- a `sessions` row is one contiguous interval it was visible. A device present
-- for an hour is ONE session (started_at..ended_at, sighting_count=N), not N
-- rows. Disappear past SESSION_GAP and return => a SECOND session. This is what
-- reconstructs "seen first at T1, gone, back at T3, gone again".

PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS devices (
    id          INTEGER PRIMARY KEY,
    kind        TEXT    NOT NULL,          -- 'wifi_ap' | 'ble'
    address     TEXT    NOT NULL,          -- BSSID / BLE MAC (may be randomized)
    first_seen  INTEGER NOT NULL,          -- epoch, first ever sighting
    last_seen   INTEGER NOT NULL,          -- epoch, most recent sighting
    meta        TEXT,                      -- JSON: ssid, channel, freq, enc,
                                           --   vendor_oui, ble_name, addr_type…
    UNIQUE(kind, address)
);

CREATE TABLE IF NOT EXISTS sessions (
    id             INTEGER PRIMARY KEY,
    device_id      INTEGER NOT NULL REFERENCES devices(id),
    started_at     INTEGER NOT NULL,       -- first sighting of this interval
    last_sight     INTEGER NOT NULL,       -- last sighting within this interval
    ended_at       INTEGER,                -- NULL while still present
    sighting_count INTEGER NOT NULL DEFAULT 1,
    rssi_min       INTEGER,
    rssi_max       INTEGER,
    rssi_last      INTEGER,
    clock_synced   INTEGER NOT NULL DEFAULT 0, -- 1 if NTP had synced at started_at
    synced         INTEGER NOT NULL DEFAULT 0  -- 1 once uploaded to IoT Core
);

-- At most one open session per device; fast to find.
CREATE INDEX IF NOT EXISTS idx_sessions_open ON sessions(device_id) WHERE ended_at IS NULL;
-- Closed-but-not-uploaded selection for the submit daemon.
CREATE INDEX IF NOT EXISTS idx_sessions_sync ON sessions(synced, ended_at);

-- Wi-Fi uplink reputation / blacklist, keyed per BSSID (an open SSID can be
-- healthy at one AP and dead at another). See §9 of the design doc.
CREATE TABLE IF NOT EXISTS net_health (
    id              INTEGER PRIMARY KEY,
    bssid           TEXT    NOT NULL UNIQUE,
    ssid            TEXT,
    is_open         INTEGER NOT NULL DEFAULT 0,
    last_attempt    INTEGER,
    last_success    INTEGER,
    fail_count      INTEGER NOT NULL DEFAULT 0,  -- consecutive failures
    last_fail_reason TEXT,                         -- assoc|dhcp|captive|no_internet|dns
    cooldown_until  INTEGER NOT NULL DEFAULT 0    -- skip this BSSID until this epoch
);

-- Device telemetry (boot beacons, future status) queued for opportunistic
-- upload, decoupled from delivery so a boot with no uplink is still reported
-- later with its real timestamp. See §5.4 of the design doc.
CREATE TABLE IF NOT EXISTS events (
    id           INTEGER PRIMARY KEY,
    ts           INTEGER NOT NULL,        -- when the event occurred (epoch)
    type         TEXT    NOT NULL,        -- 'boot' | 'status' | …
    clock_synced INTEGER NOT NULL DEFAULT 0,
    payload      TEXT,                    -- JSON detail
    synced       INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_events_sync ON events(synced);
