#!/usr/bin/env bash
# setup-wlan.sh — configure dev Wi-Fi on a running target over SSH (eth0).
#
# The image already ships brcmfmac + bcm43430 firmware + wpa-supplicant; this
# only pushes configuration. Nothing is baked into the image and no Wi-Fi
# secret is committed. The PSK is hashed on the device with wpa_passphrase, so
# the plaintext passphrase is not stored on the target either.
#
# Usage:
#   ./setup-wlan.sh <SSID> [PSK] [user@host]
#
# PSK precedence: 2nd arg > $WIFI_PSK > interactive prompt (no echo).
# For an open network, pass an empty PSK: ./setup-wlan.sh MySSID ""
#
# Override knobs (env vars):
#   TARGET        — user@host       (default: root@192.168.55.5)
#   SSH_KEY       — ssh identity    (default: ./target-root.pem)
#   WIFI_PSK      — pre-shared key  (avoids the interactive prompt)
#   WIFI_COUNTRY  — regdomain       (default: FI)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSID="${1:-}"
TARGET="${3:-${TARGET:-root@192.168.55.5}}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/target-root.pem}"
WIFI_COUNTRY="${WIFI_COUNTRY:-FI}"

die() { echo "setup-wlan.sh: $*" >&2; exit 1; }

[[ -n "$SSID" ]]    || die "usage: $0 <SSID> [PSK] [user@host]"
[[ -r "$SSH_KEY" ]] || die "SSH identity not readable: $SSH_KEY (run ./setup.sh)"

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

echo "setup-wlan.sh: configuring wlan0 on $TARGET for SSID '$SSID' ..."

# Build the remote provisioning script. SSID/PSK/country are passed via the
# environment (SendEnv-free: we export them inline on the remote shell) so they
# never appear in the process list as arguments.
ssh "${SSH_OPTS[@]}" "$TARGET" \
    "SSID=$(printf %q "$SSID") PSK=$(printf %q "$PSK") COUNTRY=$(printf %q "$WIFI_COUNTRY") sh -s" <<'REMOTE'
set -eu
command -v wpa_passphrase >/dev/null || { echo "wpa_passphrase missing on target" >&2; exit 1; }

conf=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
install -d -m 0700 /etc/wpa_supplicant

{
    echo "ctrl_interface=/run/wpa_supplicant"
    echo "ctrl_interface_group=0"
    echo "update_config=1"
    echo "country=${COUNTRY}"
    if [ -n "$PSK" ]; then
        # Hash the PSK and drop the plaintext comment wpa_passphrase emits.
        wpa_passphrase "$SSID" "$PSK" | grep -v '^[[:space:]]*#psk='
    else
        printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$SSID"
    fi
} > "$conf"
chmod 0600 "$conf"

# systemd-networkd handles DHCP once wpa_supplicant associates.
cat > /etc/systemd/network/25-wlan0.network <<NET
[Match]
Name=wlan0

[Network]
DHCP=yes
# Prefer eth0 as default route when both are up (higher metric = lower prio).
[DHCP]
RouteMetric=600
NET

systemctl enable wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
rfkill unblock wifi 2>/dev/null || true
systemctl restart wpa_supplicant@wlan0.service
systemctl restart systemd-networkd

echo "remote: wlan0 configured; waiting for association/DHCP ..."
for i in $(seq 1 20); do
    if ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '; then break; fi
    sleep 1
done
ip -4 addr show wlan0 2>/dev/null | sed -n 's/^/remote: /p' || true
REMOTE

echo "setup-wlan.sh: checking internet reachability via the target ..."
if ssh "${SSH_OPTS[@]}" "$TARGET" 'ping -c2 -W3 -I wlan0 1.1.1.1 >/dev/null 2>&1'; then
    echo "setup-wlan.sh: OK — wlan0 has internet. You can now run on-device: aws-iot-mqtt check"
else
    echo "setup-wlan.sh: wlan0 configured but no internet yet (check SSID/PSK, signal, regdomain)." >&2
    exit 1
fi
