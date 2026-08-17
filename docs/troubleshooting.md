# Symptoms and causes

Each of these cost at least one boot cycle. Recorded in the order they appear
during a build, not the order they were found.

## Installation

**`Install OtherOS` fails in Evilnat's OtherOS Tools.** Needs a full power
cycle after `setup_flash_for_otheros`, and QA flags enabled.

**`create_hdd_region.sh` reports `ps3hvc_hvcall: not found` over SSH.** A
non-interactive SSH session to petitboot gets a minimal PATH. Prefix with
`PATH=/bin:/sbin:/usr/bin:/usr/sbin`.

**Partitions come out the wrong size.** Petitboot's `parted` mishandles `GiB`
and `%` in `mkpart`. Use sectors with an explicit `s` suffix.

## Boot

**`ALERT! /dev/ps3dd1 does not exist`, unusable shell.** `CONFIG_DEVTMPFS` not
set, so `/dev` is never populated. The shell being unusable is the same cause —
no device nodes means no console input. `rootdelay` will not help.

**Initramfs shell has no keyboard.** USB HID and the host controllers are
modules and `mkinitramfs` did not include them. Build them in.

**Root not found despite the device existing.** The PS3's storage probe is
asynchronous and keeps scanning until nothing new appears for 60 seconds. Add
`rootdelay=30`.

**`root=/dev/ps3dd1` never appears under Linux.** Petitboot's kernel exposes
every region; a mainline kernel with the region patch exposes one, named
`ps3da`. Use `ps3da1` and `ps3da2` in `yaboot.conf` and `fstab`.

**`ext4_check_descriptors: Block bitmap for group N not in group`.** Either the
filesystem was built by petitboot's e2fsprogs 1.41.12, or the `ps3disk` offset
bug. Build the image on the development machine; if it persists, apply
`0001`.

Do not reach for `noblock_validity`. It disables the check that catches this
and lets the boot proceed to a more confusing failure later.

**`failed to initialize system zone (-117)`.** Same cause. EUCLEAN from the
metadata overlap pass.

**Binaries that exist return `Permission denied`, then `ENOENT`, then
`Not a directory` on successive boots.** The `ps3disk` offset bug. The varying
errno is the diagnostic: request segmentation differs between boots, so a
different part of the filesystem is corrupt each time.

Confirm it by hashing the raw partition from both kernels:

```
# petitboot
dd if=/dev/ps3dd1 bs=1M count=4096 | md5sum
# Debian initramfs, break=bottom
dd if=/dev/ps3da1 bs=1M count=4096 | md5sum
```

Differing hashes on the same bytes is conclusive.

**`run-init: can't execute '/sbin/init'`.** Check whether `/usr/sbin/init`
exists before assuming a symlink problem. A `mke2fs -d` built image can pass
`e2fsck` while containing an almost empty `/usr`.

**Image writes silently truncate.** `gunzip -c img.gz | dd of=...` writes short
reads as short blocks. Busybox `dd` has no `iflag=fullblock`. Use `cat` or a
plain redirect, and verify by hash before booting.

## systemd

**`Failed to mount API filesystems`, `Freezing execution`.** No cgroup v2.
`CONFIG_CGROUPS` and `CONFIG_NAMESPACES` are both off in `ps3_defconfig`.

**`Failed to find module 'autofs4'`.** Cosmetic if autofs is built in. Not the
cause of the freeze above.

**Modules not found at runtime.** Check `uname -r` against `/lib/modules`.
Patching the tree makes `setlocalversion` append `-dirty`; `.scmversion` no
longer overrides this as of 5.19. Use `CONFIG_LOCALVERSION` with
`CONFIG_LOCALVERSION_AUTO` disabled, and reinstall modules so the paths match.

## Petitboot

**SSH connects then hangs at key exchange.** Petitboot regenerates its host key
every boot, so host key warnings are expected and not a signal. If dropbear
accepts the connection but never completes, check for more than one instance on
port 22 — running both a network setup script and a dropbear fix script will do
it.

**No FAT support in the Debian initramfs.** A minimal kernel config cannot read
the USB stick from the initramfs shell, so scripts that log to it only work
under petitboot. From the Debian side it is console output only.
