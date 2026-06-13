#!/usr/bin/env bash
# provision-device.sh — push AWS IoT device cert + key onto a running target.
#
# The device certificate and private key are deliberately kept OUT of the image
# and out of git. This script copies them over the existing SSH channel into
# /etc/aws-iot/certs on the target, fixes permissions, and runs the on-device
# self-test (aws-iot-mqtt check).
#
# Usage:
#   ./provision-device.sh <device.crt> <device.key> [user@host]
#
# Defaults:
#   host : root@192.168.55.5   (the project's static eth0 address)
#   key  : ./target-root.pem   (the SSH identity from setup.sh)
#
# Override knobs (env vars):
#   TARGET   — user@host          (default: root@192.168.55.5)
#   SSH_KEY  — ssh identity file  (default: ./target-root.pem)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CRT="${1:-}"
KEY="${2:-}"
TARGET="${3:-${TARGET:-root@192.168.55.5}}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/target-root.pem}"

die() { echo "provision-device.sh: $*" >&2; exit 1; }

[[ -n "$CRT" && -n "$KEY" ]] \
    || die "usage: $0 <device.crt> <device.key> [user@host]"
[[ -r "$CRT" ]]     || die "device cert not readable: $CRT"
[[ -r "$KEY" ]]     || die "device key not readable: $KEY"
[[ -r "$SSH_KEY" ]] || die "SSH identity not readable: $SSH_KEY (run ./setup.sh)"

grep -q "BEGIN CERTIFICATE"     "$CRT" || die "$CRT does not look like a PEM certificate"
grep -q "PRIVATE KEY"           "$KEY" || die "$KEY does not look like a PEM private key"

# The target is reflashed often, so its host key changes every time. Skip
# host-key checking and keep it out of ~/.ssh/known_hosts so a stale entry
# can't block provisioning. (Fine for a trusted point-to-point LAN link;
# don't reuse these opts for anything reachable off the local segment.)
SSH_OPTS=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
)

echo "provision-device.sh: copying cert + key to $TARGET:/etc/aws-iot/certs ..."
ssh "${SSH_OPTS[@]}" "$TARGET" 'install -d -m 0700 /etc/aws-iot/certs'
scp "${SSH_OPTS[@]}" "$CRT" "$TARGET:/etc/aws-iot/certs/device.crt"
scp "${SSH_OPTS[@]}" "$KEY" "$TARGET:/etc/aws-iot/certs/device.key"
ssh "${SSH_OPTS[@]}" "$TARGET" '
    chmod 0644 /etc/aws-iot/certs/device.crt &&
    chmod 0600 /etc/aws-iot/certs/device.key &&
    rm -f /var/lib/aws-iot-provisioned.stamp'

echo "provision-device.sh: running on-device self-test ..."
ssh "${SSH_OPTS[@]}" "$TARGET" 'aws-iot-mqtt check'

echo "provision-device.sh: done."
