#!/usr/bin/env bash
# Apply both driver patches to a PS3 kernel tree.
#
#   ./kernel-patch.sh [kernel-tree]
#
# Both patches touch only drivers/block/ps3disk.c. Nothing outside that file
# is modified, so drivers/ps3/ps3stor_lib.c stays pristine and ps3flash and
# ps3rom keep upstream behaviour.
#
# Generated against the pristine v6.4 tag. 0001 applies with a small offset
# to Geoff Levand's tree; 0002 applies on top of 0001.

set -euo pipefail

KDIR="${1:-$HOME/ps3-linux}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DISK="$KDIR/drivers/block/ps3disk.c"

[ -f "$DISK" ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

apply() {
    local patch="$1" marker="$2" name="$3"

    if grep -q "$marker" "$DISK"; then
        echo "$name: already applied"
        return
    fi
    if ! patch -d "$KDIR" -p1 --forward --backup --suffix=.orig < "$patch"; then
        echo "$name: did not apply to $KDIR" >&2
        exit 1
    fi
    echo "$name: applied"
}

apply "$HERE/patches/0001-ps3disk-restore-bounce-buffer-offset.patch" \
      'offset += bvec.bv_len' '0001 bounce buffer offset'

apply "$HERE/patches/0002-ps3disk-expose-every-accessible-storage-region.patch" \
      'ps3disk_find_otheros_region' '0002 multiple regions'

# Confirm the result rather than trusting the exit status. Both of these
# print nothing if the patches silently went to the wrong place.
echo
echo "=== bounce buffer offset ==="
sed -n '/^static void ps3disk_scatter_gather/,/^}/p' "$DISK"

echo "=== region selection ==="
grep -n 'set_disk_ro\|rp->region_idx\|module_param_named' "$DISK"

echo
echo "=== ps3stor_lib.c must be untouched ==="
if grep -q '__fls(dev->accessible_regions)' "$KDIR/drivers/ps3/ps3stor_lib.c"; then
    echo "WARNING: the old __fls hack is still present. Revert it:" >&2
    echo "  cd $KDIR && git checkout drivers/ps3/ps3stor_lib.c" >&2
    exit 1
fi
echo "clean"
