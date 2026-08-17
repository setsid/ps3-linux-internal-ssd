#!/bin/sh
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

PATH=/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(dirname "$0")
DEV=/dev/ps3dd
STAMP=/tmp/partition-ok

rm -f "$STAMP"

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

echo
echo "=== unmounting ==="
for m in $(grep "^${DEV}[12] " /proc/mounts | cut -d' ' -f2); do
    umount "$m" 2>/dev/null || umount -l "$m"
done
grep "^${DEV}[12] " /proc/mounts && { echo "still mounted, stopping"; exit 1; }

echo
echo "=== partitioning ==="
parted -s "$DEV" unit s mklabel gpt
parted -s "$DEV" unit s mkpart primary ext2 ${ROOT_START}s ${ROOT_END}s
parted -s "$DEV" unit s mkpart primary linux-swap ${SWAP_START}s ${SWAP_END}s
sleep 2
parted -s "$DEV" unit s print

echo
echo "=== kernel view ==="
grep ps3dd /proc/partitions
echo "ps3dd1 should be 18873344"

# Only swap gets formatted here. The root filesystem is written as a whole
# image built on the development machine - petitboot's e2fsprogs is 1.41.12
# from 2010 and produces group descriptors that 6.4 ext4 rejects.
echo
echo "=== mkswap ==="
mkswap -L ps3swap "${DEV}2"

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
