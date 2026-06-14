#!/usr/bin/env bash
# add-network.sh — register a known Wi-Fi network for the OPPORTUNISTIC uplink.
#
# This is the counterpart to setup-wlan.sh, for two different modes of wlan0:
#
#   setup-wlan.sh  → DEV mode: pins wlan0 to one AP *permanently* (persistent
#                    wpa_supplicant-wlan0.conf + enabled wpa_supplicant@wlan0 +
#                    25-wlan0.network). The radio stays associated, so the
#                    collector/submit opportunistic cycle can't use it.
#
#   add-network.sh → NORMAL mode: appends a network={} block to the submit
#                    daemon's known-networks list /etc/gewgaw/networks.conf.
#                    Nothing is enabled or connected here — gewgaw-submit reads
#                    this file each run, associates *transiently* during its
#                    radio-lease window to upload, then drops the link. The
#                    collector keeps scanning the rest of the time.
#
# Like setup-wlan.sh / provision-device.sh: runtime-only, nothing is baked into
# the image and no Wi-Fi secret is committed. The PSK is hashed on the device
# with wpa_passphrase, so the plaintext passphrase is not stored on the target.
#
# Usage:
#   ./add-network.sh <SSID> [PSK] [PRIORITY]
#
# PSK precedence: 2nd arg > $WIFI_PSK > interactive prompt (no echo).
# For an open network, pass an empty PSK: ./add-network.sh CafeOpen "" 10
# PRIORITY (default 50): higher = preferred when several known APs are visible.
#
# Override knobs (env vars):
#   TARGET        — user@host       (default: root@192.168.55.5)
#   SSH_KEY       — ssh identity    (default: ./target-root.pem)
#   WIFI_PSK      — pre-shared key  (avoids the interactive prompt)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSID="${1:-}"
PRIORITY="${3:-50}"
TARGET="${TARGET:-root@192.168.55.5}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/target-root.pem}"

die() { echo "add-network.sh: $*" >&2; exit 1; }

[[ -n "$SSID" ]]    || die "usage: $0 <SSID> [PSK] [PRIORITY]"
[[ -r "$SSH_KEY" ]] || die "SSH identity not readable: $SSH_KEY (run ./setup.sh)"
[[ "$PRIORITY" =~ ^[0-9]+$ ]] || die "PRIORITY must be a non-negative integer"

# Resolve the PSK: positional arg, env, or prompt. Empty == open network.
if [[ $# -ge 2 ]]; then
    PSK="$2"
elif [[ -n "${WIFI_PSK:-}" ]]; then
    PSK="$WIFI_PSK"
else
    read -rsp "Wi-Fi passphrase for '$SSID' (empty for open network): " PSK
    echo
fi
if [[ -n "$PSK" ]]; then
    (( ${#PSK} >= 8 && ${#PSK} <= 63 )) || die "WPA passphrase must be 8..63 chars"
fi

# Reflash-friendly SSH opts (host key changes every flash); see provision-device.sh.
SSH_OPTS=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
)

echo "add-network.sh: registering SSID '$SSID' (priority $PRIORITY) on $TARGET ..."

# SSID/PSK/priority are passed via the remote environment (not as argv) so the
# secret never appears in the target's process list.
ssh "${SSH_OPTS[@]}" "$TARGET" \
    "SSID=$(printf %q "$SSID") PSK=$(printf %q "$PSK") PRIORITY=$(printf %q "$PRIORITY") sh -s" <<'REMOTE'
set -eu
command -v wpa_passphrase >/dev/null || { echo "wpa_passphrase missing on target" >&2; exit 1; }

conf=/etc/gewgaw/networks.conf
install -d -m 0755 /etc/gewgaw
[ -f "$conf" ] || { : > "$conf"; chmod 0600 "$conf"; }
chmod 0600 "$conf"

# Build the new block. For a PSK network, hash with wpa_passphrase and keep only
# the hashed psk= line (drop the plaintext #psk= comment it emits).
if [ -n "$PSK" ]; then
    psk_line=$(wpa_passphrase "$SSID" "$PSK" | sed -n 's/^[[:space:]]*psk=/    psk=/p')
    cred="$psk_line"
else
    cred="    key_mgmt=NONE"
fi
block=$(printf 'network={\n    ssid="%s"\n%s\n    priority=%s\n}\n' "$SSID" "$cred" "$PRIORITY")

# Drop any existing block for the same SSID (so re-running updates in place),
# then append the new one. awk tracks network={...} blocks and suppresses the
# one whose ssid matches $SSID.
tmp=$(mktemp)
awk -v want="$SSID" '
    /^[[:space:]]*network=\{/ { inblk=1; buf=$0 ORS; drop=0; next }
    inblk {
        buf = buf $0 ORS
        if ($0 ~ /ssid="/) {
            line=$0; sub(/.*ssid="/,"",line); sub(/".*/,"",line)
            if (line == want) drop=1
        }
        if ($0 ~ /^[[:space:]]*\}/) { if (!drop) printf "%s", buf; inblk=0 }
        next
    }
    { print }
' "$conf" > "$tmp"
printf '%s\n' "$block" >> "$tmp"
mv "$tmp" "$conf"
chmod 0600 "$conf"

echo "remote: $conf now lists known SSIDs:"
grep -E 'ssid="' "$conf" | sed -E 's/.*ssid="([^"]*)".*/  - \1/'
REMOTE

echo "add-network.sh: done."
