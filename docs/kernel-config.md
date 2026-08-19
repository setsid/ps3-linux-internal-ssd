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

`CONFIG_USB`, `CONFIG_USB_EHCI_HCD`, `CONFIG_USB_OHCI_HCD`, `CONFIG_HID`,
`CONFIG_USB_HID`

As modules these may not make it into the initramfs, leaving an emergency shell
you cannot type at.

`CONFIG_USB` is set for its dependents rather than for itself. `ps3_defconfig`
has it as `m`, and Kconfig will not hold a symbol at `y` while something it
depends on is `m`, so `olddefconfig` demoted the two host controllers and
`USB_HID` back to modules on every run - after the script had set them. Setting
`USB` is what makes the other three stay built in.

### cgroups

`CONFIG_CGROUPS` and the controllers.

systemd mounts cgroup2 on `/sys/fs/cgroup` as one of its first actions and
freezes if it cannot. Not optional, and off in `ps3_defconfig`.

Controllers beyond `CGROUPS` itself are not all strictly required for PID 1 to
survive, but leaving them out produces service failures later.

`CGROUP_PERF` is not set. It needs `CONFIG_PERF_EVENTS`, which `ps3_defconfig`
does not have, so the script used to ask for a symbol that could not exist and
the request did nothing. systemd does not use that controller, and enabling perf
on a 256 MB machine to satisfy it is not a trade worth making, so the request is
gone rather than granted.

`PROC_PID_CPUSET` was set for 6.4 and is not set now. Since the cgroup v1
controllers became separately configurable it depends on `CPUSETS_V1`, which is
deprecated and defaults to `n`, so on 6.13 or later the script asked for a
symbol it could not get and failed its own post-check. It only provides the
legacy `/proc/<pid>/cpuset` file. systemd drives cgroup v2, which `CPUSETS`
alone still gives, so the symbol is dropped rather than propped up by enabling
v1 cpuset code for an interface nothing here reads.

### namespaces

`CONFIG_NAMESPACES` and the individual types.

Required for `systemd-udevd`, `PrivateTmp=`, and most service sandboxing.

### The rest

`CONFIG_FHANDLE` for `open_by_handle_at`, `CONFIG_SECCOMP` and
`CONFIG_SECCOMP_FILTER` for service hardening, `CONFIG_FANOTIFY`,
`CONFIG_TMPFS_POSIX_ACL` and `CONFIG_TMPFS_XATTR`.

## Checking what was actually set

`kernel-config.sh` prints the resulting value of every symbol it asked for, and
exits non-zero if any of them is not `y`. A subset check is how three USB
symbols stayed modules across every build without being mentioned: the ones that
were verified were the ones that happened to work.

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

It is not fixed across trees. The 7.1.8 tarball configured by this script gives
a bare `7.1.8`; a tree built before under other settings can give something
longer. Never copy a release string out of documentation.

The trailing `+` appears when `CONFIG_LOCALVERSION_AUTO` finds a git tree whose
HEAD is not on an exact tag, so an unpacked tarball never grows one. Where it
does appear it is part of the string: `7.1.8+` and `7.1.8` are different
directories. Copy what `kernelrelease` prints, including any `+`.

Set `CONFIG_LOCALVERSION="-something"` yourself if you want a distinguishable
suffix, but it is optional. Whatever you choose, re-read `kernelrelease`
afterwards, and run `make modules_install` after the final build so the
directory name matches.

## Size

`vmlinux` comes out around 210 MB unstripped on 7.1.8. Petitboot has to kexec
it into a machine with 256 MB of RAM alongside the initrd and itself, so strip
it:

```
powerpc64-linux-gnu-strip -s -o vmlinux-stripped vmlinux
```

That gets it to 20.5 MiB, measured on the 7.1.8 build with gcc 11.4.0. The 6.4
build stripped to about 19 MiB.

## Verifying the patch survived a rebuild

```
grep -q 'offset += bvec.bv_len'       drivers/block/ps3disk.c && echo upstream fix present
grep -q 'ps3disk_find_otheros_region' drivers/block/ps3disk.c && echo 0001 ok
```

The first line is upstream as of 6.19, not something this repository applies;
`kernel-patch.sh` refuses to run without it. The second is `patches/0001`.

The patch touches only `drivers/block/ps3disk.c`. If
`drivers/ps3/ps3stor_lib.c` differs from upstream, something has gone wrong —
the earlier `__fls` hack was withdrawn, not superseded:

```
grep -q '__fls(dev->accessible_regions)' drivers/ps3/ps3stor_lib.c \
    && echo "stale __fls hack, revert this file"
```

Worth doing before every build. A `make mrproper` or a tree update will remove
them silently.
