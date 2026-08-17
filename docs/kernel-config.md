# Kernel configuration

Baseline is `ps3_defconfig` from Geoff Levand's tree. It targets the hardware
correctly and assumes a userland from around 2009.

```
git clone https://git.kernel.org/pub/scm/linux/kernel/git/geoff/ps3-linux.git ~/ps3-linux
cd ~/ps3-linux
make ARCH=powerpc ps3_defconfig
../scripts/kernel-patch.sh
../scripts/kernel-config.sh
make ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- -j$(nproc)
```

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
you cannot type at. On a machine whose only console is a television that is the
difference between debugging and reflashing.

### cgroups

`CONFIG_CGROUPS` and the controllers.

systemd mounts cgroup2 on `/sys/fs/cgroup` as one of its first actions and
freezes if it cannot. Not optional, and off in `ps3_defconfig`.

Controllers beyond `CGROUPS` itself are not all strictly required for PID 1 to
survive, but leaving them out produces service failures later that are harder
to attribute than a missing symbol.

### namespaces

`CONFIG_NAMESPACES` and the individual types.

Required for `systemd-udevd`, `PrivateTmp=`, and most service sandboxing.

### The rest

`CONFIG_FHANDLE` for `open_by_handle_at`, `CONFIG_SECCOMP` and
`CONFIG_SECCOMP_FILTER` for service hardening, `CONFIG_FANOTIFY`,
`CONFIG_TMPFS_POSIX_ACL` and `CONFIG_TMPFS_XATTR`.

## Version string

`.scmversion` was dropped from kbuild in 5.19. A patched tree therefore builds
as `-dirty`, `/lib/modules` no longer matches `uname -r`, and no module loads.

```
CONFIG_LOCALVERSION="-your-suffix"
# CONFIG_LOCALVERSION_AUTO is not set
```

A trailing `+` may still appear when HEAD is not on an exact tag. Harmless, as
long as `make modules_install` runs after the final build so the directory name
matches.

## Size

`vmlinux` comes out around 143 MB unstripped. Petitboot has to kexec it into a
machine with 256 MB of RAM alongside the initrd and itself, so strip it:

```
powerpc64-linux-gnu-strip -s -o vmlinux-stripped vmlinux
```

That gets it to roughly 19 MB.

## Verifying both patches survived a rebuild

```
grep -q 'offset += bvec.bv_len' drivers/block/ps3disk.c && echo ps3disk ok
grep -q '__fls(dev->accessible_regions)' drivers/ps3/ps3stor_lib.c && echo ps3stor ok
```

Worth doing before every build. A `make mrproper` or a tree update will remove
them silently.
