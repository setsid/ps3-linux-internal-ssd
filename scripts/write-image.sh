#!/bin/sh
# Write a gzipped root filesystem image to the OtherOS region and verify it.
# Runs at the petitboot shell. Put this and the image on a USB stick together:
#
#   sh /tmp/*/mnt/*/write-image.sh <expected-md5> [size-in-MiB]
#
# Logs to write-image-out.txt beside itself, because getting text off
# petitboot any other way means photographing a television.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(dirname "$0")
DEV=/dev/ps3dd1
IMG="$HERE/ps3root.img.gz"
EXPECT="$1"
MB="${2:-4096}"
MNT=/mnt/chk

[ -n "$EXPECT" ] || { echo "usage: write-image.sh <md5> [MiB]"; exit 1; }

{
echo "=== image ==="
ls -l "$IMG" || { echo "$IMG not found"; exit 1; }

echo
echo "=== unmounting ==="
for m in $(grep "^$DEV " /proc/mounts | cut -d' ' -f2); do
    echo "umount $m"; umount "$m" 2>/dev/null || umount -l "$m"
done
grep "^$DEV " /proc/mounts && { echo "still mounted, stopping"; exit 1; }

# cat, not dd. Busybox dd has no iflag=fullblock, so piped from gunzip it
# writes short reads as short blocks and silently truncates the image.
echo
echo "=== writing ==="
gunzip -c "$IMG" > "$DEV"
sync

echo
echo "=== verifying ==="
GOT=$(dd if="$DEV" bs=1M count="$MB" 2>/dev/null | md5sum | cut -d' ' -f1)
echo "expected $EXPECT"
echo "got      $GOT"
[ "$GOT" = "$EXPECT" ] || { echo "MISMATCH"; exit 1; }
echo "match"

echo
echo "=== contents ==="
mkdir -p "$MNT"
mount "$DEV" "$MNT" || { echo "mount failed"; exit 1; }
ls -l "$MNT/boot/vmlinux"
ls "$MNT/lib/modules"
ls -l "$MNT/usr/sbin/init"
df -h "$MNT"
cat "$MNT/etc/yaboot.conf"
sync
umount "$MNT"

echo
echo "done, reboot and select Debian"
} 2>&1 | tee /tmp/write-image-out.txt

mount -o remount,rw "$HERE" 2>/dev/null
cp /tmp/write-image-out.txt "$HERE/write-image-out.txt" 2>/dev/null
sync
