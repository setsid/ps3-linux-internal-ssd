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
# That figure is checked, not assumed. This script writes a partition table,
# and on a console whose firmware presents a different layout the assumption
# would destroy whatever is actually there, unrecoverably. If you knowingly
# have a different region size, override it:
#
#   EXPECTED_SECTORS=12345678 sh partition-region.sh

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

# Override on the command line if your layout differs and you know it does.
EXPECTED_SECTORS="${EXPECTED_SECTORS:-46137320}"

# blockdev is not always present at the petitboot shell; sysfs always is.
dev_sectors() {
    blockdev --getsz "$DEV" 2>/dev/null && return 0
    cat "/sys/class/block/${DEVNAME}/size" 2>/dev/null && return 0
    return 1
}

ROOT_START=2048
ROOT_END=37748735       # 18.0 GiB
SWAP_START=37748736
SWAP_END=46137286       # end of usable space

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
echo "  $DEV is ${ACTUAL:-unknown} sectors, expected $EXPECTED_SECTORS"

if [ -z "$ACTUAL" ]; then
    echo
    echo "REFUSING TO CONTINUE"
    echo "Could not determine the size of $DEV. Nothing was written."
    exit 1
fi

if [ "$ACTUAL" != "$EXPECTED_SECTORS" ]; then
    echo
    echo "REFUSING TO CONTINUE"
    echo "$DEV is $ACTUAL sectors, expected $EXPECTED_SECTORS."
    echo
    echo "This does not look like the OtherOS region this script was written"
    echo "for, and partitioning it would destroy whatever is there. Nothing"
    echo "has been written."
    echo
    echo "If your layout really is different and you know the size is right:"
    echo "  EXPECTED_SECTORS=$ACTUAL sh \$0"
    exit 1
fi

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
echo "ps3dd1 should be 18873344"

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
