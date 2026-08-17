#!/usr/bin/env bash
# Build a bootable root filesystem image from a debootstrapped tree.
# Runs on the development machine.
#
#   sudo ./build-image.sh [rootfs-dir] [output.img] [blocks]
#
# Default 1048576 4k blocks = 4 GiB. The OtherOS region gives you ~22 GiB;
# size the image to suit and resize2fs later from inside Debian if needed.
#
# This script only packages a tree that build-rootfs.sh built (README step 0)
# and that step 4 installed a kernel into. It creates no accounts, sets no
# passwords, and installs nothing - build-rootfs.sh prompts for the root and
# user passwords during its own run. This repository ships no credentials of
# any kind.

set -euo pipefail

ROOTFS="${1:-/srv/ps3root}"
IMG="${2:-/tmp/ps3root4g.img}"
BLOCKS="${3:-1048576}"
MNT=$(mktemp -d)

# The verification below can exit early while the image is still mounted.
cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

[ -d "$ROOTFS/usr/bin" ] || { echo "no rootfs at $ROOTFS" >&2; exit 1; }

# ^metadata_csum,^64bit keeps the on-disk format to what an old kernel and a
# modern e2fsprogs both agree on
mke2fs -t ext4 -b 4096 -O ^metadata_csum,^64bit -L ps3root -F "$IMG" "$BLOCKS"

mount -o loop "$IMG" "$MNT"

# cp -a rather than mke2fs -d: the latter produced a tree that passed fsck
# but was missing almost everything under /usr
cp -a "$ROOTFS/." "$MNT/"

# The tree keeps qemu-ppc64-static so step 4 can chroot into it on hosts whose
# binfmt handler lacks the F flag. The console has no use for it.
rm -f "$MNT/usr/bin/qemu-ppc64-static"

echo
echo "verifying"
# A tree where step 4's mkinitramfs failed otherwise packages cleanly and fails
# at boot, which costs a full write-and-boot cycle to discover.
[ -f "$MNT/boot/vmlinux" ] || { echo "no /boot/vmlinux - see README step 4" >&2; exit 1; }
[ -f "$MNT/boot/initrd.img" ] || { echo "no /boot/initrd.img - see README step 4" >&2; exit 1; }
ls "$MNT/usr"
ls -l "$MNT/usr/sbin/init" "$MNT/boot/vmlinux" "$MNT/boot/initrd.img"
ls "$MNT/lib/modules"
du -sh "$MNT"
df -h "$MNT"

umount "$MNT"
rmdir "$MNT"

e2fsck -fn "$IMG"

echo
md5sum "$IMG"
echo "gzip -1 this onto the USB stick, then run write-image.sh from petitboot"
