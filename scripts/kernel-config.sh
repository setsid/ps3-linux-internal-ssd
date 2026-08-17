#!/usr/bin/env bash
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

# /dev is never populated without these, so the initramfs cannot find root
# and the emergency shell has no console
"$CFG" --enable DEVTMPFS
"$CFG" --enable DEVTMPFS_MOUNT

# built in, not modules - the initramfs shell needs a keyboard before
# any module could be loaded
"$CFG" --enable USB_EHCI_HCD
"$CFG" --enable USB_OHCI_HCD
"$CFG" --enable HID
"$CFG" --enable USB_HID

# systemd will not start PID 1 without cgroup v2
"$CFG" --enable CGROUPS
"$CFG" --enable MEMCG
"$CFG" --enable CGROUP_SCHED
"$CFG" --enable FAIR_GROUP_SCHED
"$CFG" --enable CGROUP_PIDS
"$CFG" --enable CGROUP_FREEZER
"$CFG" --enable CGROUP_DEVICE
"$CFG" --enable CGROUP_CPUACCT
"$CFG" --enable CGROUP_PERF
"$CFG" --enable CGROUP_BPF
"$CFG" --enable CPUSETS
"$CFG" --enable PROC_PID_CPUSET
"$CFG" --enable BLK_CGROUP

"$CFG" --enable NAMESPACES
"$CFG" --enable UTS_NS
"$CFG" --enable IPC_NS
"$CFG" --enable PID_NS
"$CFG" --enable NET_NS
"$CFG" --enable USER_NS

"$CFG" --enable FHANDLE
"$CFG" --enable SECCOMP
"$CFG" --enable SECCOMP_FILTER
"$CFG" --enable FANOTIFY
"$CFG" --enable EVENTFD
"$CFG" --enable TMPFS_POSIX_ACL
"$CFG" --enable TMPFS_XATTR
"$CFG" --enable EXT4_FS_POSIX_ACL
"$CFG" --enable EXT4_FS_SECURITY
"$CFG" --enable CONFIGFS_FS
"$CFG" --enable AUTOFS_FS
"$CFG" --enable BPF
"$CFG" --enable BPF_SYSCALL
"$CFG" --enable KEYS
"$CFG" --enable PERSISTENT_KEYRINGS
"$CFG" --enable CRYPTO_USER_API_HASH
"$CFG" --enable CRYPTO_HMAC
"$CFG" --enable CRYPTO_SHA256

# kbuild ignores .scmversion since 5.19; set the suffix properly so the
# release string stays stable and /lib/modules keeps matching
"$CFG" --disable LOCALVERSION_AUTO

make ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- olddefconfig

# Kconfig dependencies can silently drop symbols, so check rather than assume
echo
grep -E '^CONFIG_(DEVTMPFS|CGROUPS|MEMCG|NAMESPACES|USER_NS|FHANDLE|SECCOMP|FANOTIFY|TMPFS_POSIX_ACL|AUTOFS_FS)' .config
grep -E 'LOCALVERSION' .config
