#!/bin/sh
# SPDX-License-Identifier: MIT
# Partition the OtherOS region. Runs at the petitboot shell.
#   sh /tmp/petitboot/mnt/sda1/partition-region.sh
#
# Destroys everything on ps3dd1 and ps3dd2.
#
# Sizes are raw 512-byte sectors throughout. The parted in petitboot
# mishandles GiB and % arguments - asking for 18GiB produced a 6 GiB
# partition, and 100% produced 10 GiB.
#
# Region geometry as created by glevand's create_hdd_region.sh on Evilnat
# 4.93: 46137320 sectors, fixed regardless of drive size.
#
# The layout is derived from the region's measured size rather than hardcoded,
# so a region of another size is partitioned correctly instead of being either
# refused or silently mangled. On the standard 46137320-sector region the
# derivation reproduces the documented numbers exactly: root 2048-37748735,
# swap 37748736-46137286.
#
# Root is a fixed size, swap gets the remainder. Override the root size if you
# want a different split:
#
#   ROOT_GIB=12 sh partition-region.sh

PATH=/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(dirname "$0")
DEV=/dev/ps3dd
DEVNAME=ps3dd
STAMP=/tmp/partition-ok

# Nothing here checked an exit status, so a parted that crashed and a mkswap
# that failed on a missing device both still wrote the stamp and reported
# success. Every step that can fail now stops the script.
run_or_die() {
    desc=$1; shift
    "$@" || {
        echo
        echo "FAILED: $desc"
        echo "command: $*"
        exit 1
    }
}

# parted writes the table, but the running kernel may not re-read it. Seen on
# petitboot's 2.6.30: parted's own print listed both partitions while
# /proc/partitions had only ps3dd1, so mkswap failed on a node that did not
# exist. None of these are guaranteed to be present; try each.
reread_table() {
    partprobe "$DEV" 2>/dev/null && return 0
    blockdev --rereadpt "$DEV" 2>/dev/null && return 0
    hdparm -z "$DEV" 2>/dev/null && return 0
    return 1
}

# Exact field match on /proc/partitions rather than a substring of the line.
have_partitions() {
    awk -v a="${DEVNAME}1" -v b="${DEVNAME}2" \
        '$4==a{f1=1} $4==b{f2=1} END{exit !(f1 && f2)}' /proc/partitions
}

rm -f "$STAMP"

ROOT_GIB="${ROOT_GIB:-18}"

SECTORS_PER_GIB=2097152
STANDARD_SECTORS=46137320   # Evilnat 4.93, for reporting only
GPT_TAIL=34                 # parted keeps the backup header in the last sectors
MIN_SWAP_SECTORS=1048576    # 512 MiB - below this, do not bother

# A sanity envelope rather than an exact figure. It is wide enough for any
# plausible OtherOS region and narrow enough that pointing this at region 0,
# the whole 915 GB drive, is refused rather than partitioned.
MIN_REGION_SECTORS=$((8 * SECTORS_PER_GIB))
MAX_REGION_SECTORS=$((128 * SECTORS_PER_GIB))

# blockdev is not always present at the petitboot shell; sysfs always is.
dev_sectors() {
    blockdev --getsz "$DEV" 2>/dev/null && return 0
    cat "/sys/class/block/${DEVNAME}/size" 2>/dev/null && return 0
    return 1
}

ROOT_START=2048

{
echo "=== paths ==="
# Enumeration order is not guaranteed once other USB devices are attached, so
# print what this actually resolved to rather than assuming sda1.
echo "stick:  $HERE"
echo "target: $DEV"

echo
echo "=== before ==="
grep ps3dd /proc/partitions

# Refuse to touch anything that is not the layout this script was written for.
# The kernel patch goes out of its way to keep GameOS read-only; the script
# that writes partition tables should be at least as careful.
echo
echo "=== checking the target ==="
for d in ps3da ps3db ps3dc ps3dd; do
    if [ -b "/dev/$d" ] || grep -q "[[:space:]]$d\$" /proc/partitions; then
        echo "  /dev/$d present"
    else
        echo
        echo "REFUSING TO CONTINUE"
        echo "/dev/$d is missing, so this is not the expected OtherOS++ layout"
        echo "or the disk has not finished enumerating. Nothing was written."
        exit 1
    fi
done

ACTUAL=$(dev_sectors) || ACTUAL=""

if [ -z "$ACTUAL" ]; then
    echo
    echo "REFUSING TO CONTINUE"
    echo "Could not determine the size of $DEV. Nothing was written."
    exit 1
fi

echo "  $DEV is $ACTUAL sectors"

if [ "$ACTUAL" -lt "$MIN_REGION_SECTORS" ] || [ "$ACTUAL" -gt "$MAX_REGION_SECTORS" ]; then
    echo
    echo "REFUSING TO CONTINUE"
    echo "$DEV is $ACTUAL sectors, outside the range this script will touch"
    echo "($MIN_REGION_SECTORS to $MAX_REGION_SECTORS, i.e. 8 GiB to 128 GiB)."
    echo
    echo "An OtherOS region is not that size. If this is region 0 - the whole"
    echo "physical drive - partitioning it would destroy GameOS. Nothing has"
    echo "been written."
    exit 1
fi

# Derive the layout from what is actually there.
ROOT_SECTORS=$((ROOT_GIB * SECTORS_PER_GIB))
ROOT_END=$((ROOT_SECTORS - 1))
SWAP_START=$ROOT_SECTORS
SWAP_END=$((ACTUAL - GPT_TAIL))

if [ "$SWAP_END" -le "$((SWAP_START + MIN_SWAP_SECTORS))" ]; then
    echo
    echo "REFUSING TO CONTINUE"
    echo "A ${ROOT_GIB} GiB root leaves no room for swap in $ACTUAL sectors."
    echo "Use a smaller root, for example:"
    echo "  ROOT_GIB=$(( (ACTUAL - MIN_SWAP_SECTORS - GPT_TAIL) / SECTORS_PER_GIB )) sh \$0"
    echo "Nothing has been written."
    exit 1
fi

if [ "$ACTUAL" = "$STANDARD_SECTORS" ]; then
    echo "  standard Evilnat OtherOS region"
else
    echo "  non-standard region size - layout derived from it, not assumed"
fi
echo "  root: ${ROOT_START}s to ${ROOT_END}s (${ROOT_GIB} GiB)"
echo "  swap: ${SWAP_START}s to ${SWAP_END}s ($(( (SWAP_END - SWAP_START + 1) / 2048 )) MiB)"

echo
echo "=== unmounting ==="
for m in $(grep "^${DEV}[12] " /proc/mounts | cut -d' ' -f2); do
    umount "$m" 2>/dev/null || umount -l "$m"
done
grep "^${DEV}[12] " /proc/mounts && { echo "still mounted, stopping"; exit 1; }

echo
echo "=== partitioning ==="
run_or_die "parted mklabel gpt" \
    parted -s "$DEV" unit s mklabel gpt
run_or_die "parted mkpart root" \
    parted -s "$DEV" unit s mkpart primary ext2 ${ROOT_START}s ${ROOT_END}s
run_or_die "parted mkpart swap" \
    parted -s "$DEV" unit s mkpart primary linux-swap ${SWAP_START}s ${SWAP_END}s
sleep 2
run_or_die "parted print" \
    parted -s "$DEV" unit s print

echo
echo "=== waiting for the kernel to see both partitions ==="
tries=0
while [ "$tries" -lt 8 ]; do
    have_partitions && break
    echo "  ${DEVNAME}2 not present yet, asking the kernel to re-read"
    reread_table || echo "  no re-read method available"
    sleep 2
    tries=$((tries + 1))
done

if ! have_partitions; then
    echo
    grep ps3dd /proc/partitions
    echo
    echo "The table was written - parted's print above lists both partitions -"
    echo "but this kernel has not re-read it, so ${DEV}2 does not exist and"
    echo "swap cannot be formatted."
    echo
    echo "Reboot petitboot and run this script again. The table survives the"
    echo "reboot, so the second run finds both partitions and continues. It is"
    echo "safe to re-run: it rewrites the same table at the same offsets."
    echo
    echo "Do NOT run write-image.sh until this script finishes cleanly."
    exit 1
fi

echo
echo "=== kernel view ==="
grep ps3dd /proc/partitions
echo "ps3dd1 should be $(( (ROOT_END - ROOT_START + 1) / 2 ))"

# Only swap gets formatted here. The root filesystem is written as a whole
# image built on the development machine - petitboot's e2fsprogs is 1.41.12
# from 2010 and produces group descriptors that 6.4 ext4 rejects.
echo
echo "=== mkswap ==="
run_or_die "mkswap on ${DEV}2" mkswap -L ps3swap "${DEV}2"

# Confirm the label is really there. At boot the generated swap unit waits on
# /dev/disk/by-label/ps3swap and times out after 90 seconds if it is not, and
# an old signature surviving from a previous run can otherwise make a failed
# mkswap look like it worked.
echo
echo "=== swap label ==="
blkid "${DEV}2" 2>&1
blkid "${DEV}2" 2>/dev/null | grep -q 'LABEL="ps3swap"' || {
    echo "FAILED: no ps3swap label on ${DEV}2 after mkswap"
    exit 1
}
echo "ps3swap label confirmed"

# Last act of the block. Anything above that exits early skips this, which is
# how the real status escapes the subshell that `| tee` creates.
echo ok > "$STAMP"
} 2>&1 | tee /tmp/partition-out.txt

mount -o remount,rw "$HERE" 2>/dev/null
cp /tmp/partition-out.txt "$HERE/partition-out.txt" 2>/dev/null

# Cumulative session log. The per-script files above are overwritten on every
# run; a session spans both scripts, so append here to keep it readable as one.
{
    echo
    echo "===== partition  $(date 2>/dev/null || echo 'no clock') ====="
    cat /tmp/partition-out.txt
} >> "$HERE/petitboot-log.txt" 2>/dev/null
sync

if [ ! -f "$STAMP" ]; then
    echo "FAILED - see partition-out.txt on the stick" >&2
    exit 1
fi
exit 0
