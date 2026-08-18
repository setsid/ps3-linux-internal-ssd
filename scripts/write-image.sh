#!/bin/sh
# SPDX-License-Identifier: MIT
# Write a gzipped root filesystem image to the OtherOS region and verify it.
# Runs at the petitboot shell. Put this and the image on a USB stick together:
#
#   sh /tmp/petitboot/mnt/sda1/write-image.sh [md5] [image.gz] [size-in-MiB]
#
# With no arguments it reads manifest.txt from beside itself, which
# make-debian-installer.sh writes when it prepares the stick. That is the whole
# point of the manifest: it saves transcribing a 32-character hash at a
# television, on a USB keyboard, late at night.
#
# Arguments override the manifest, in case you build an image by hand:
# the md5, then the image name, then its size in MiB.
#
# Logs to write-image-out.txt beside itself, because getting text off
# petitboot any other way means photographing a television.


PATH=/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(dirname "$0")

# One accent colour, green for success, red for failure, bold for the thing
# that must not be got wrong. Off when not a terminal, when TERM is dumb, or
# when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    B=$(printf '\033[1m');  N=$(printf '\033[0m')
    G=$(printf '\033[32m'); R=$(printf '\033[31m')
    C=$(printf '\033[36m'); D=$(printf '\033[2m')
else
    B=; N=; G=; R=; C=; D=
fi
DEV=/dev/ps3dd1
REGION=/dev/ps3dd
REGNAME=ps3dd

# The md5 pass afterwards catches a bad write. It does not catch a write to the
# right-looking name on the wrong layout, because by then the data is gone. So
# check the geometry first and write nothing on a mismatch. Override if you
# knowingly have a different region size.
EXPECTED_SECTORS="${EXPECTED_SECTORS:-46137320}"
ROOT_MIN_SECTORS="${ROOT_MIN_SECTORS:-36000000}"   # ~17.2 GiB
ROOT_MAX_SECTORS="${ROOT_MAX_SECTORS:-39000000}"   # ~18.6 GiB

dev_sectors() {
    blockdev --getsz "$1" 2>/dev/null && return 0
    cat "/sys/class/block/$2/size" 2>/dev/null && return 0
    return 1
}
EXPECT="${1:-}"
IMG_NAME="${2:-}"
MB="${3:-}"
MNT=/mnt/chk
MANIFEST="$HERE/manifest.txt"

# A hash is 32 hex digits and nothing else. The stick is FAT32 and manifest.txt
# is readable from Windows, so a CR from an editor there would otherwise turn a
# good write into a reported mismatch - and a verifier that cries wolf on good
# data is worse than none.
hexonly() { printf '%s' "$1" | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f'; }

# Fill in whatever was not given from the manifest.
if [ -f "$MANIFEST" ]; then
    [ -n "$EXPECT" ]   || EXPECT=$(sed -n 's/^md5=//p' "$MANIFEST" | head -1)
    [ -n "$IMG_NAME" ] || IMG_NAME=$(sed -n 's/^image=//p' "$MANIFEST" | head -1)
    [ -n "$MB" ]       || MB=$(sed -n 's/^size_mib=//p' "$MANIFEST" | head -1)
    USED_MANIFEST=yes
else
    USED_MANIFEST=no
fi

# Strip anything an editor on Windows may have added - the stick is FAT32.
IMG_NAME=$(printf '%s' "$IMG_NAME" | tr -d '\r')
IMG="$HERE/${IMG_NAME:-ps3root4g.img.gz}"
MB=$(printf '%s' "$MB" | tr -cd '0-9')
[ -n "$MB" ] || MB=4096
EXPECT=$(hexonly "$EXPECT")
STAMP=/tmp/write-image-ok

rm -f "$STAMP"

[ -n "$EXPECT" ] || {
    echo "No md5 given and no manifest.txt beside this script."
    echo "usage: write-image.sh <md5> [image.gz] [MiB]"
    exit 1; }

# Catch a mangled hash before writing rather than after.
if [ "${#EXPECT}" -ne 32 ]; then
    echo "md5 is not 32 hex characters: [$EXPECT]"
    echo "check manifest.txt on the stick, or pass the hash directly"
    exit 1
fi

{
echo "=== paths ==="
# Enumeration order is not guaranteed once other USB devices are attached, so
# print what this actually resolved to rather than assuming sda1.
echo "stick:  $HERE"
echo "image:  $IMG"
echo "target: $DEV"
echo "size:   $MB MiB"
echo "md5:    $EXPECT"
if [ "$USED_MANIFEST" = yes ]; then
    echo "source: manifest.txt"
    sed -n 's/^kernel_release=/kernel: /p;s/^built=/built:  /p' "$MANIFEST"
else
    echo "source: command line"
fi

echo
echo "=== checking the target ==="
RSEC=$(dev_sectors "$REGION" "$REGNAME") || RSEC=""
PSEC=$(dev_sectors "$DEV" "${REGNAME}1") || PSEC=""
echo "$REGION: ${RSEC:-unknown} sectors, expected $EXPECTED_SECTORS"
echo "$DEV: ${PSEC:-unknown} sectors, expected $ROOT_MIN_SECTORS-$ROOT_MAX_SECTORS"

if [ "$RSEC" != "$EXPECTED_SECTORS" ]; then
    echo
    echo "This does not look like the expected OtherOS++ layout."
    echo "Expected $REGION = $EXPECTED_SECTORS sectors"
    echo "Found    $REGION = ${RSEC:-unknown} sectors"
    echo "Nothing has been written."
    exit 1
fi

if [ -z "$PSEC" ] || [ "$PSEC" -lt "$ROOT_MIN_SECTORS" ] \
   || [ "$PSEC" -gt "$ROOT_MAX_SECTORS" ]; then
    echo
    echo "$DEV is ${PSEC:-unknown} sectors, not the ~18 GiB root partition"
    echo "this image is built for. Run partition-region.sh first and let it"
    echo "finish cleanly."
    echo "Nothing has been written."
    exit 1
fi
echo "layout looks right"

echo
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
GOT=$(hexonly "$(dd if="$DEV" bs=1M count="$MB" 2>/dev/null | md5sum | cut -d' ' -f1)")
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
#
# A hard check, not a listing. This section used to print whatever blkid found
# and carry on: a run where ps3dd2 did not exist showed one line under a heading
# saying both must be found, and then reported success. A check that passes when
# the thing it checks is absent is worse than no check.
echo
echo "=== labels (both must be found) ==="
blkid "$DEV" /dev/ps3dd2 2>&1

for pair in "$DEV ps3root" "/dev/ps3dd2 ps3swap"; do
    d=${pair% *}
    want=${pair#* }
    out=$(blkid "$d" 2>/dev/null)
    case "$out" in
        *"LABEL=\"$want\""*) ;;
        *)
            echo
            echo "MISSING: $d has no $want label"
            echo "Run partition-region.sh and let it finish cleanly, then"
            echo "run this script again."
            exit 1 ;;
    esac
done
echo "both labels confirmed"

echo
echo "write complete and verified"

# Last act of the block. Anything above that exits early skips this, which is
# how the real status escapes the subshell that `| tee` creates.
echo ok > "$STAMP"
} 2>&1 | tee /tmp/write-image-out.txt

mount -o remount,rw "$HERE" 2>/dev/null
cp /tmp/write-image-out.txt "$HERE/write-image-out.txt" 2>/dev/null

# Cumulative session log. The per-script files above are overwritten on every
# run; a session spans both scripts, so append here to keep it readable as one.
{
    echo
    echo "===== write-image  $(date 2>/dev/null || echo 'no clock') ====="
    cat /tmp/write-image-out.txt
} >> "$HERE/petitboot-log.txt" 2>/dev/null
sync

if [ ! -f "$STAMP" ]; then
    echo "${R}${B}FAILED.${N} Nothing was booted and nothing is lost." >&2
    echo "The full log is on the stick: write-image-out.txt" >&2
    echo "Do not reboot into Debian - the image is incomplete." >&2
    exit 1
fi

# Printed to the terminal only, after the log has been copied, so the log files
# on the stick stay free of escape sequences.
echo
echo "${G}${B}Write complete and verified.${N}"
echo "The image on ${DEV} matches the expected hash."
echo
echo "${C}What to do now${N}"
echo
echo "  1. Reboot the console."
echo "  2. At the petitboot menu choose ${B}debian${N} - the first entry."
echo "     ${B}Not debian-failsafe.${N} That exists only for the case where the"
echo "     first entry drops you at an initramfs prompt. Choosing it by"
echo "     mistake boots with several hardware features switched off for no"
echo "     reason."
echo
echo "The USB stick is finished with. Leave it in or take it out - Debian does"
echo "not need it. This session's logs are at the root of the stick:"
echo "  ${D}$HERE/partition-out.txt${N}"
echo "  ${D}$HERE/write-image-out.txt${N}"
echo "  ${D}$HERE/petitboot-log.txt${N}"
echo
echo "SSH is enabled and the machine takes a DHCP address as eth0, so you can"
echo "log in over the network instead of using the television. First boot is"
echo "slow - 256 MB of RAM doing first-boot service setup."
echo
exit 0
