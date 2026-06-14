#!/usr/bin/env bash
# boot.sh — reboot the running target over SSH, and (by default) wait for it to
# come back. A small dev convenience for retesting the boot/submit cycle.
#
# Like the other host helpers (provision-device.sh, add-network.sh, setup-wlan.sh)
# it is runtime-only and uses reflash-tolerant SSH opts (no host-key checking, as
# the target's key changes on every flash).
#
# Usage:
#   ./boot.sh            # reboot and wait until SSH is back
#   ./boot.sh --no-wait  # fire the reboot and return immediately
#
# Override knobs (env vars):
#   TARGET    — user@host          (default: root@192.168.55.5)
#   SSH_KEY   — ssh identity file  (default: ./target-root.pem)
#   WAIT_SECS — max seconds to wait for the target to return (default: 180)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${TARGET:-root@192.168.55.5}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/target-root.pem}"
WAIT_SECS="${WAIT_SECS:-180}"

WAIT=1
[[ "${1:-}" == "--no-wait" ]] && WAIT=0

die() { echo "boot.sh: $*" >&2; exit 1; }

[[ -r "$SSH_KEY" ]] || die "SSH identity not readable: $SSH_KEY (run ./setup.sh)"

SSH_OPTS=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o ConnectTimeout=5
)

echo "boot.sh: rebooting $TARGET ..."
# `systemctl reboot` drops the connection as it goes down; that closes our SSH
# session with a non-zero status, which is expected — don't treat it as failure.
ssh "${SSH_OPTS[@]}" "$TARGET" 'systemctl reboot' || true

if [[ "$WAIT" -eq 0 ]]; then
    echo "boot.sh: reboot issued (not waiting)."
    exit 0
fi

echo "boot.sh: waiting up to ${WAIT_SECS}s for $TARGET to come back ..."
# Give it a moment to actually go down before we start probing, so we don't just
# reconnect to the still-up pre-reboot system.
sleep 5
deadline=$(( $(date +%s) + WAIT_SECS ))
while (( $(date +%s) < deadline )); do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" 'true' 2>/dev/null; then
        up="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'uptime -p 2>/dev/null || uptime' 2>/dev/null || true)"
        echo "boot.sh: $TARGET is back (${up:-up})."
        exit 0
    fi
    sleep 3
done

die "target did not return within ${WAIT_SECS}s"
