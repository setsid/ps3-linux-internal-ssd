#!/bin/sh
# Write a gzipped root filesystem image to the OtherOS region and verify it.
# Runs at the petitboot shell. Put this and the image on a USB stick together:
#
#   sh /tmp/*/mnt/*/write-image.sh <expected-md5> [image.gz] [size-in-MiB]
#
# The md5, image name and size are arguments rather than constants because they
# change with every build. build-image.sh prints the md5 when it finishes.
# The image name defaults to ps3root4g.img.gz, matching README step 5. Pass it
# if you build a different size, for example ps3root18g.img.gz.
#
# Logs to write-image-out.txt beside itself, because getting text off
# petitboot any other way means photographing a television.
#
# This is the generic form of a procedure that was run repeatedly during
# development in ad-hoc variants with the hash written into the script. The
# sequence below is what worked; this exact file has not itself been run on
# hardware. See docs/troubleshooting.md.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(dirname "$0")
DEV=/dev/ps3dd1
EXPECT="$1"
IMG="$HERE/${2:-ps3root4g.img.gz}"
MB="${3:-4096}"
MNT=/mnt/chk
STAMP=/tmp/write-image-ok

rm -f "$STAMP"

[ -n "$EXPECT" ] || {
    echo "usage: write-image.sh <md5> [image.gz] [MiB]"; exit 1; }

{
echo "=== image ==="
ls -l "$IMG" || { echo "$IMG not found"; exit 1; }

# Petitboot auto-mounts every filesystem it can read, so the target is always
# mounted by the time you get here - typically at /tmp/petitboot/mnt/ps3dd1.
echo
echo "=== unmounting ==="
for m in $(grep "^$DEV " /proc/mounts | cut -d' ' -f2); do
    echo "umount $m"; umount "$m" 2>/dev/null || umount -l "$m"
done
grep "^$DEV " /proc/mounts && { echo "STILL MOUNTED - stopping"; exit 1; }

# A plain redirect, never piped into dd. Busybox dd has no iflag=fullblock, so
# reading from a pipe it treats a short read as a short block and stops early,
# silently truncating the image. It reports success. This cost hours: the
# filesystem mounts, passes fsck, and then fails much later in ways that look
# like filesystem corruption rather than a bad write.
echo
echo "=== writing ==="
gunzip -c "$IMG" > "$DEV"
sync

# Verify before booting, always. A truncated write is indistinguishable from a
# good one until something reads the part that is missing.
echo
echo "=== md5 verify ==="
GOT=$(dd if="$DEV" bs=1M count="$MB" 2>/dev/null | md5sum | cut -d' ' -f1)
echo "expected $EXPECT"
echo "got      $GOT"
[ "$GOT" = "$EXPECT" ] || { echo "MISMATCH - stopping"; exit 1; }
echo "MATCH"

# Eyeball the kernel and the boot configuration now rather than discovering a
# mistake after a 40 minute write-and-boot cycle.
echo
echo "=== content ==="
mkdir -p "$MNT"
mount "$DEV" "$MNT" || { echo "mount failed"; exit 1; }

# Hard checks, not just a listing. This is the last gate before a boot cycle,
# and an ls error scrolling past on a television is not a check.
for f in /boot/vmlinux /boot/initrd.img /usr/sbin/init; do
    if [ ! -e "$MNT$f" ]; then
        echo "MISSING $f - this image will not boot"
        umount "$MNT"
        exit 1
    fi
done

echo "--- kernel"
ls -l "$MNT/boot/vmlinux" "$MNT/boot/initrd.img"
echo "--- modules"
ls "$MNT/lib/modules"
echo "--- init"
ls -l "$MNT/usr/sbin/init"
echo "--- yaboot.conf"
cat "$MNT/etc/yaboot.conf"
echo "--- fstab"
cat "$MNT/etc/fstab"
df -h "$MNT"
sync
umount "$MNT"

# Root boots by LABEL=, so the labels have to resolve. e2label is not present
# in petitboot; blkid is.
echo
echo "=== labels (both must be found) ==="
blkid "$DEV" /dev/ps3dd2

echo
echo "done - reboot and select Debian"

# Last act of the block. Anything above that exits early skips this, which is
# how the real status escapes the subshell that `| tee` creates.
echo ok > "$STAMP"
} 2>&1 | tee /tmp/write-image-out.txt

mount -o remount,rw "$HERE" 2>/dev/null
cp /tmp/write-image-out.txt "$HERE/write-image-out.txt" 2>/dev/null
sync

if [ ! -f "$STAMP" ]; then
    echo "FAILED - see write-image-out.txt on the stick" >&2
    exit 1
fi
exit 0
