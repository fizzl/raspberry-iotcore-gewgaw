#!/bin/sh
# grow-rootfs.sh — first-boot root partition and filesystem expansion.
#
# Extends partition 2 on mmcblk0 to fill all remaining SD card space, then
# resizes the ext4 filesystem to match. Runs once; a stamp file prevents
# subsequent executions.
set -e

# Extend the on-disk partition table entry to fill remaining space.
# --no-reread suppresses the ioctl that would fail on a mounted partition;
# partx below updates the kernel's in-memory view instead.
printf ', +\n' | sfdisk --no-reread -N 2 /dev/mmcblk0

# Inform the kernel of the updated partition boundary.
partx -u /dev/mmcblk0

# Extend the ext4 filesystem to fill the now-larger partition (online resize).
resize2fs /dev/mmcblk0p2
