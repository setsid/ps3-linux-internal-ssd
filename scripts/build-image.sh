#!/usr/bin/env bash
# Build a bootable root filesystem image from a debootstrapped tree.
# Runs on the development machine.
#
#   sudo ./build-image.sh [rootfs-dir] [output.img] [blocks]
#
# Default 1048576 4k blocks = 4 GiB. The OtherOS region gives you ~22 GiB;
# size the image to suit and resize2fs later from inside Debian if needed.

set -euo pipefail

ROOTFS="${1:-/srv/ps3root}"
IMG="${2:-/tmp/ps3root.img}"
BLOCKS="${3:-1048576}"
MNT=$(mktemp -d)

[ -d "$ROOTFS/usr/bin" ] || { echo "no rootfs at $ROOTFS" >&2; exit 1; }

# ^metadata_csum,^64bit keeps the on-disk format to what an old kernel and a
# modern e2fsprogs both agree on
mke2fs -t ext4 -b 4096 -O ^metadata_csum,^64bit -L ps3root -F "$IMG" "$BLOCKS"

mount -o loop "$IMG" "$MNT"

# cp -a rather than mke2fs -d: the latter produced a tree that passed fsck
# but was missing almost everything under /usr
cp -a "$ROOTFS/." "$MNT/"

echo
echo "verifying"
ls "$MNT/usr"
ls -l "$MNT/usr/sbin/init" "$MNT/boot/vmlinux"
ls "$MNT/lib/modules"
du -sh "$MNT"
df -h "$MNT"

umount "$MNT"
rmdir "$MNT"

e2fsck -fn "$IMG"

echo
md5sum "$IMG"
echo "gzip -1 this onto the USB stick, then run write-image.sh from petitboot"
