# Kernel configuration

Baseline is `ps3_defconfig` from Geoff Levand's tree. It targets the hardware
correctly and assumes a userland from around 2009.

```
git clone https://git.kernel.org/pub/scm/linux/kernel/git/geoff/ps3-linux.git ~/ps3-linux
make -C ~/ps3-linux ARCH=powerpc ps3_defconfig
./scripts/kernel-patch.sh ~/ps3-linux
./scripts/kernel-config.sh ~/ps3-linux
make -C ~/ps3-linux ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- -j$(nproc)
```

Run these from the root of this repository, as the README steps do.

A bare `make`, not `make vmlinux`. The bare target builds `vmlinux` and the
modules together; `vmlinux` alone skips modules entirely, and the install step
then has nothing to install.

Apply the config script once, after `ps3_defconfig`. Re-running `ps3_defconfig`
discards everything.

## Why each group is needed

### devtmpfs

`CONFIG_DEVTMPFS`, `CONFIG_DEVTMPFS_MOUNT`

Without these nothing creates `/dev`, so the initramfs cannot find the root
device however long it waits, and the emergency shell has no console because
there is no tty node either. This presents as a device that "does not exist"
rather than as a timing problem, which sends you looking at `rootdelay`.

### USB input built in

`CONFIG_USB_EHCI_HCD`, `CONFIG_USB_OHCI_HCD`, `CONFIG_HID`, `CONFIG_USB_HID`

As modules these may not make it into the initramfs, leaving an emergency shell
you cannot type at.

### cgroups

`CONFIG_CGROUPS` and the controllers.

systemd mounts cgroup2 on `/sys/fs/cgroup` as one of its first actions and
freezes if it cannot. Not optional, and off in `ps3_defconfig`.

Controllers beyond `CGROUPS` itself are not all strictly required for PID 1 to
survive, but leaving them out produces service failures later.

### namespaces

`CONFIG_NAMESPACES` and the individual types.

Required for `systemd-udevd`, `PrivateTmp=`, and most service sandboxing.

### The rest

`CONFIG_FHANDLE` for `open_by_handle_at`, `CONFIG_SECCOMP` and
`CONFIG_SECCOMP_FILTER` for service hardening, `CONFIG_FANOTIFY`,
`CONFIG_TMPFS_POSIX_ACL` and `CONFIG_TMPFS_XATTR`.

## Version string

`.scmversion` was dropped from kbuild in 5.19. With `CONFIG_LOCALVERSION_AUTO`
left on, a patched tree builds as `-dirty`, `/lib/modules` no longer matches
`uname -r`, and no module loads.

`kernel-config.sh` therefore disables it:

```
# CONFIG_LOCALVERSION_AUTO is not set
```

and sets nothing else. It does **not** set `CONFIG_LOCALVERSION` — the release
string is whatever the tree already produces, so read it from the tree:

```
make -s kernelrelease
```

That string is the directory name under `/lib/modules`, and it is the argument
`mkinitramfs` needs in README step 4.

It is not fixed across trees. A clean clone configured by this script gives
`6.4.0+`; a tree built before under other settings can give something longer.
Never copy a release string out of documentation.

The trailing `+` appears when HEAD is not on an exact tag and is part of the
string: `6.4.0+` and `6.4.0` are different directories. Copy what
`kernelrelease` prints, including any `+`.

Set `CONFIG_LOCALVERSION="-something"` yourself if you want a distinguishable
suffix, but it is optional. Whatever you choose, re-read `kernelrelease`
afterwards, and run `make modules_install` after the final build so the
directory name matches.

## Size

`vmlinux` comes out around 143 MB unstripped. Petitboot has to kexec it into a
machine with 256 MB of RAM alongside the initrd and itself, so strip it:

```
powerpc64-linux-gnu-strip -s -o vmlinux-stripped vmlinux
```

That gets it to roughly 19 MB.

## Verifying both patches survived a rebuild

```
grep -q 'offset += bvec.bv_len'      drivers/block/ps3disk.c && echo 0001 ok
grep -q 'ps3disk_find_otheros_region' drivers/block/ps3disk.c && echo 0002 ok
```

Both patches touch only `drivers/block/ps3disk.c`. If
`drivers/ps3/ps3stor_lib.c` differs from upstream, something has gone wrong —
the earlier `__fls` hack was withdrawn, not superseded:

```
grep -q '__fls(dev->accessible_regions)' drivers/ps3/ps3stor_lib.c \
    && echo "stale __fls hack, revert this file"
```

Worth doing before every build. A `make mrproper` or a tree update will remove
them silently.
