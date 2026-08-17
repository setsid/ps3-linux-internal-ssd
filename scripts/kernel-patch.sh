#!/usr/bin/env bash
# Apply both driver patches to a PS3 kernel tree.
# Locates the lines by content, so it survives context drift between trees.
#
#   ./kernel-patch.sh [kernel-tree]

set -euo pipefail

KDIR="${1:-$HOME/ps3-linux}"
DISK="$KDIR/drivers/block/ps3disk.c"
STOR="$KDIR/drivers/ps3/ps3stor_lib.c"

[ -f "$DISK" ] || { echo "not a kernel tree: $KDIR" >&2; exit 1; }

if grep -q 'offset += bvec.bv_len' "$DISK"; then
    echo "ps3disk: already patched"
else
    cp "$DISK" "$DISK.orig"
    python3 - "$DISK" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "\t\t\tmemcpy_to_bvec(&bvec, dev->bounce_buf + offset);\n"
if needle not in s:
    sys.exit("ps3disk: expected line not found, tree differs from 6.4")
open(p, "w").write(s.replace(needle, needle + "\n\t\toffset += bvec.bv_len;\n", 1))
PY
    echo "ps3disk: patched"
fi

if grep -q '__fls(dev->accessible_regions)' "$STOR"; then
    echo "ps3stor: already patched"
else
    cp "$STOR" "$STOR.orig"
    sed -i 's|\tdev->region_idx = __ffs(dev->accessible_regions);|\tif (dev->sbd.match_id == PS3_MATCH_ID_STOR_DISK)\n\t\tdev->region_idx = __fls(dev->accessible_regions);\n\telse\n\t\tdev->region_idx = __ffs(dev->accessible_regions);|' "$STOR"
    grep -q '__fls(dev->accessible_regions)' "$STOR" || {
        echo "ps3stor: patch did not apply" >&2; exit 1; }
    echo "ps3stor: patched"
fi

echo
sed -n '/ps3disk_scatter_gather/,/^}/p' "$DISK"
grep -n -B2 -A4 '__fls(dev->accessible_regions)' "$STOR"
