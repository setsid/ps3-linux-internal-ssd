#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Apply the driver patch to a PS3 kernel tree.
#
#   ./kernel-patch.sh [kernel-tree]
#
# The patch touches only drivers/block/ps3disk.c. Nothing outside that file
# is modified, so drivers/ps3/ps3stor_lib.c stays pristine and ps3flash and
# ps3rom keep upstream behaviour.
#
# Generated against the pristine v7.1.8 tag.
#
# The bounce buffer offset fix that used to be patch 0001 here is upstream as
# of 6.19, backported to 6.18.44, 6.12.103 and 6.6.151. It is checked for
# below rather than applied, because on a kernel that has it the patch would
# fail and on a kernel that lacks it every multi-segment transfer is silently
# corrupt. Either way the tree has to be looked at, not assumed.

set -euo pipefail

KDIR="${1:-$HOME/ps3-linux}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="$KDIR/drivers/block/ps3disk.c"

# Works both from scripts/ inside the repository and from a flat directory
# holding the patch next to this script.
PATCHFILE=""
for candidate in \
    "$HERE/../patches/0001-ps3disk-expose-every-accessible-storage-region.patch" \
    "$HERE/0001-ps3disk-expose-every-accessible-storage-region.patch"; do
    [ -f "$candidate" ] && { PATCHFILE="$candidate"; break; }
done
[ -n "$PATCHFILE" ] || { echo "cannot find the region patch near $HERE" >&2; exit 1; }

[ -f "$DISK" ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

if ! grep -q 'offset += bvec.bv_len' "$DISK"; then
    echo "$DISK is missing the bounce buffer offset increment." >&2
    echo >&2
    echo "This kernel predates René Rebe's fix and every multi-segment" >&2
    echo "transfer will be corrupt: each bio vector is copied to the start" >&2
    echo "of the bounce buffer. It shows up as ext4 group descriptor damage" >&2
    echo "long after the write that caused it." >&2
    echo >&2
    echo "Use 7.1.8, or 6.18.44 or newer, or 6.12.103, or 6.6.151. If you must stay on" >&2
    echo "this kernel, take the fix from the 6.4 tag of this repository." >&2
    exit 1
fi

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

apply "$PATCHFILE" \
      'ps3disk_find_otheros_region' '0001 multiple regions'

# Confirm the result rather than trusting the exit status. These print nothing
# if the patch silently went to the wrong place.
echo
echo "=== bounce buffer offset (upstream) ==="
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
