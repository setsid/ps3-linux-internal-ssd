#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Layer the options a modern Debian userland needs on top of ps3_defconfig.
# Run after ps3_defconfig, and after kernel-patch.sh.
#
#   ./kernel-config.sh [kernel-tree]
#
# Do not re-run ps3_defconfig after this; it will discard everything below.

set -euo pipefail

KDIR="${1:-$HOME/ps3-linux}"
CFG="$KDIR/scripts/config"
cd "$KDIR"

# Every symbol here has to end up built in, not a module. One list, used twice -
# once to set and once to verify - so that what the script asks for and what it
# checks cannot drift apart. They had: three of these were silently modules.
BUILTIN="
# /dev is never populated without these, so the initramfs cannot find root and
# the emergency shell has no console.
DEVTMPFS DEVTMPFS_MOUNT

# Built in, not modules. The initramfs shell needs a keyboard before anything
# could load a module, and on a machine whose only console is a television a
# prompt you cannot type at ends the debugging session.
#
# USB is on this list although nothing here asks for it directly. The two host
# controllers and USB_HID all depend on it and ps3_defconfig sets it to m, and a
# symbol cannot be y while a dependency is m - so olddefconfig put all three
# back to m on every run, a few lines after they were set. Setting USB itself is
# what makes the other three stick.
USB USB_EHCI_HCD USB_OHCI_HCD HID USB_HID

# systemd will not start PID 1 without cgroup v2.
CGROUPS MEMCG CGROUP_SCHED FAIR_GROUP_SCHED CGROUP_PIDS CGROUP_FREEZER
CGROUP_DEVICE CGROUP_CPUACCT CGROUP_BPF CPUSETS PROC_PID_CPUSET BLK_CGROUP

# CGROUP_PERF is deliberately not here. It needs PERF_EVENTS, which
# ps3_defconfig does not set, so the request could never be satisfied and did
# nothing at all. systemd does not use the controller, and pulling perf
# machinery into a 256 MB machine to satisfy it is not worth the kernel it adds.

# Required for systemd-udevd, PrivateTmp= and most service sandboxing.
NAMESPACES UTS_NS IPC_NS PID_NS NET_NS USER_NS

FHANDLE SECCOMP SECCOMP_FILTER FANOTIFY EVENTFD TMPFS_POSIX_ACL TMPFS_XATTR
EXT4_FS_POSIX_ACL EXT4_FS_SECURITY CONFIGFS_FS AUTOFS_FS BPF BPF_SYSCALL
KEYS PERSISTENT_KEYRINGS CRYPTO_USER_API_HASH CRYPTO_HMAC CRYPTO_SHA256
"

builtin_symbols() {
    printf '%s\n' "$BUILTIN" | sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$'
}

# --set-val rather than --enable. Both write =y, but --set-val says outright
# that the existing value is being replaced, which is the whole point here.
for sym in $(builtin_symbols); do
    "$CFG" --set-val "$sym" y
done

# kbuild ignores .scmversion since 5.19; turn the suffix off properly so the
# release string stays stable and /lib/modules keeps matching uname -r
"$CFG" --disable LOCALVERSION_AUTO

make ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- olddefconfig

# Print all of them, not a chosen few. Kconfig can demote or drop any symbol
# here depending on what it needs, and a subset check is exactly how three of
# these stayed modules through every build without ever being mentioned.
echo
echo "=== resulting values ==="
notbuiltin=
for sym in $(builtin_symbols); do
    val=$(grep -E "^CONFIG_$sym=" .config || true)
    if [ "$val" = "CONFIG_$sym=y" ]; then
        printf '  %s\n' "$val"
    else
        printf '  %-34s %s  <-- wanted y\n' "CONFIG_$sym" "${val:-not set}"
        notbuiltin="$notbuiltin $sym"
    fi
done
echo
grep -E 'LOCALVERSION' .config

if [ -n "$notbuiltin" ]; then
    echo
    echo "FAILED: these did not end up built in:$notbuiltin"
    echo "Something each one depends on is still a module or unset. Left as"
    echo "modules they may not reach the initrd, which is how the emergency"
    echo "shell loses its keyboard. Fix this before building."
    exit 1
fi

# This is the string /lib/modules will be named after, and the argument
# mkinitramfs needs in README step 4. Read it, do not guess it.
echo
echo "kernel release: $(make -s ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- kernelrelease)"
