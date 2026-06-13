#!/usr/bin/env bash
# flash.sh — write the built gewgaw image to a removable device.
#
# Usage:
#   ./flash.sh /dev/sdX
#
# Guardrails (the script refuses to proceed otherwise):
#   * the target must be a whole block device, not a partition;
#   * the device must be removable (/sys/block/<dev>/removable == 1);
#   * none of its partitions may be mounted;
#   * the device size and current partition table are shown and an
#     explicit confirmation is required before the destructive write.
#
# Override knobs (env vars, matching build.sh):
#   IMAGE      — bitbake target image (default: core-image-base)
#   MACHINE    — target machine        (default: raspberrypi3)
#   BUILD_DIR  — build directory name  (default: build)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-core-image-base}"
MACHINE="${MACHINE:-raspberrypi3}"
BUILD_DIR="${BUILD_DIR:-build}"

log()  { printf '[flash] %s\n'        "$*"; }
warn() { printf '[flash] WARN: %s\n'  "$*" >&2; }
die()  { printf '[flash] ERROR: %s\n' "$*" >&2; exit 1; }

# --- argument -------------------------------------------------------------
[[ $# -eq 1 ]] || die "usage: $0 /dev/sdX  (target device is mandatory)"
DEVICE="$1"

[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Canonicalise (follow symlinks like /dev/disk/by-id/...) and reject partitions.
DEVICE="$(readlink -f "$DEVICE")"
DEV_NAME="$(basename "$DEVICE")"

if [[ ! -e "/sys/block/$DEV_NAME" ]]; then
    die "$DEVICE is not a whole disk (looks like a partition). Pass the disk, e.g. /dev/sda not /dev/sda1."
fi

# --- guardrail: removable -------------------------------------------------
removable="$(cat "/sys/block/$DEV_NAME/removable" 2>/dev/null || echo 0)"
[[ "$removable" == "1" ]] \
    || die "$DEVICE is not a removable device (removable=$removable). Refusing to write to it."

# --- guardrail: not mounted ----------------------------------------------
mounted="$(lsblk -nro MOUNTPOINT "$DEVICE" | sed '/^$/d' || true)"
if [[ -n "$mounted" ]]; then
    warn "$DEVICE has mounted partitions:"
    printf '  %s\n' $mounted >&2
    die "Unmount them first (e.g. sudo umount ${DEVICE}*) and re-run."
fi

# --- locate image artifacts ----------------------------------------------
DEPLOY_DIR="$REPO_ROOT/$BUILD_DIR/tmp/deploy/images/$MACHINE"
IMG="$DEPLOY_DIR/${IMAGE}-${MACHINE}.rootfs.wic.bz2"
BMAP="$DEPLOY_DIR/${IMAGE}-${MACHINE}.rootfs.wic.bmap"

[[ -f "$IMG" ]]  || die "Image not found: $IMG  (run ./build.sh first)"
[[ -f "$BMAP" ]] || die "Block map not found: $BMAP  (run ./build.sh first)"

command -v bmaptool >/dev/null 2>&1 \
    || die "bmaptool not found. Install it (Debian/Ubuntu: sudo apt-get install bmap-tools)."

# --- show target & confirm ------------------------------------------------
log "About to flash:"
log "  image:  $(readlink -f "$IMG")"
echo
log "Target device $DEVICE:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE"
echo

warn "This will DESTROY ALL DATA on $DEVICE."
read -r -p "[flash] Type the device path ($DEVICE) to confirm: " reply
[[ "$reply" == "$DEVICE" ]] || die "Confirmation did not match; aborting. Nothing was written."

# --- write ----------------------------------------------------------------
log "Writing image to $DEVICE ..."
sudo bmaptool copy --bmap "$BMAP" "$IMG" "$DEVICE"
sync

log "Done. You can now remove $DEVICE and boot the Raspberry Pi."
log "Connect with: ssh -i $REPO_ROOT/target-root.pem root@192.168.55.5"
