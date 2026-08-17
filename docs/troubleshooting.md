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
asynchronous, so the root device may not exist yet when the initramfs first
looks for it. Add `rootdelay=30`.

The two numbers are not measuring the same thing. The probe keeps scanning for
*further* storage devices for up to 60 seconds before it stops expecting more;
the internal drive itself appears well inside 30. `rootdelay=30` has been
enough on every boot here, and raising it to 60 only makes a successful boot
slower.

**`root=/dev/ps3dd1` never appears under Linux.** A mainline kernel without
`patches/0002` exposes one region and calls it `ps3da`, whatever it contains.
With `0002` every accessible region appears under the same name petitboot uses,
so `ps3dd1` is correct in both.

If you are coming from the first version of `0002` — the `__fls` hack — your
configuration says `ps3da1` and needs to say `ps3dd1`. See
[migration.md](migration.md).

**`mkfs` or `dd` to `/dev/ps3db` fails with `EACCES` or `EPERM`.** Working as
intended. Everything except the OtherOS region is read-only by default, because
region 1 is the GameOS installation. If you genuinely mean it,
`ps3disk.writable=<mask>` on the kernel command line.

**A region is missing from `/proc/partitions`.** Check `dmesg` for the
`not selected` / `not accessible` lines the driver prints for every region it
skips. `not selected` means `ps3disk.regions=` excluded it; `not accessible`
means the hypervisor refused the probe read.

**`ps3disk ...: device busy, deferring request` in `dmesg`.** Should never
appear. It means two region queues tried to submit at once and the driver
refused the second rather than corrupting the bounce buffer. No data is lost,
but the serialisation argument in `docs/region-handling.md` does not hold on
that kernel — report it before trusting the filesystem.

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
dd if=/dev/ps3dd1 bs=1M count=4096 | md5sum
```

The two commands are identical on purpose — that is the point. Since `0002`
both kernels call the region `ps3dd`, so this reads the same bytes off the same
device through two different drivers. Under v1 the second would have been
`ps3da1`. Differing hashes on the same bytes is conclusive.

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

**`Timed out waiting for device dev-disk-by\x2dlabel-ps3swap.device`, and swap
never activates.** `/dev/disk` does not exist at all. Check with `ls /dev/disk`
— if that fails, this is the cause.

systemd's `60-persistent-storage.rules` matches `sd*`, `sr*`, `vd*`, `mmcblk*`,
`cciss*` and `pmem*`. PS3 block devices are `ps3d*` and match none of them, so
the `blkid` builtin never runs, no `ID_FS_*` properties are set, and none of
the `/dev/disk/by-*` trees are created. Anything resolved by label or UUID
*through udev* then fails.

Root still boots, which is what makes this confusing: the initramfs resolves
`root=LABEL=` itself without udev. But the swap unit systemd generates from
`fstab` waits on `/dev/disk/by-label/ps3swap`, which nothing ever creates, and
gives up after 90 seconds.

This is an upstream systemd gap, not a kernel or patch problem, and it affects
any PS3 running a modern systemd. The fix is
`scripts/61-ps3-persistent-storage.rules`, installed to `/etc/udev/rules.d/`
by `build-rootfs.sh`. Verify it took:

```
ls -l /dev/disk/by-label/     # ps3root and ps3swap both present
blkid /dev/ps3dd1 /dev/ps3dd2
```

Both were confirmed working on hardware with the rule in place.

**Modules not found at runtime.** Check `uname -r` against `/lib/modules`.
Patching the tree makes `setlocalversion` append `-dirty`; `.scmversion` no
longer overrides this as of 5.19. `kernel-config.sh` disables
`CONFIG_LOCALVERSION_AUTO`, which stops that; reinstall modules after the final
build so the paths match. Read the expected name with `make -s kernelrelease`
rather than guessing it, and include any trailing `+`. See
[kernel-config.md](kernel-config.md).

## Network and apt

**apt hangs or crawls on the `Packages` index.** Observed on the console:
`https` to `deb.debian.org` failed where plain `http` worked, and large index
downloads were extremely slow with `rx_dropped` climbing on the interface.

Not diagnosed, so no cause is claimed here. The workaround that unblocked it
was switching `/etc/apt/sources.list` to `http`, which is what
`build-rootfs.sh` writes. `ca-certificates` is installed regardless, so `https`
is available once whatever this is has been sorted out.

## Petitboot

**SSH connects then hangs at key exchange.** Petitboot regenerates its host key
every boot, so host key warnings are expected and not a signal. If dropbear
accepts the connection but never completes, check for more than one instance on
port 22 — running both a network setup script and a dropbear fix script will do
it.

**No FAT support in the Debian initramfs.** A minimal kernel config cannot read
the USB stick from the initramfs shell, so scripts that log to it only work
under petitboot. From the Debian side it is console output only.

## Things that were not the problem

Recorded because each cost at least one rebuild cycle before being ruled out.
When the storage path is corrupting data, everything above it looks broken, so
the temptation is to keep changing the filesystem.

- filesystem size, block count, or feature flags
- GPT versus MBR
- 64 KiB versus 4 KiB pages
- `noblock_validity` — silences the descriptor check without fixing anything,
  which turns an early clean failure into a later confusing one
- the "Skip all ACL Checks" LV1 patch in Evilnat's CFW settings, in either state
- symlink handling across the usr-merge during `run-init`

The actual cause of all of it was the bounce buffer offset, `patches/0001`.
The diagnostic that settles it in one step is hashing the same bytes from both
kernels: if `dd if=/dev/ps3dd1 bs=1M count=4096 | md5sum` differs between
petitboot's 2.6.30 and the 6.4 kernel, the filesystem is fine and the driver is
not.

## Region layout reference

Evilnat 4.93 reserves a fixed 46137320 sectors, about 22 GiB, for OtherOS
regardless of drive size. Confirmed identical on a 320 GB HDD and a 960 GB SSD.
`scripts/partition-region.sh` splits it 18 GiB root plus the remainder as swap:

```
parted -s /dev/ps3dd unit s mklabel gpt
parted -s /dev/ps3dd unit s mkpart primary ext2 2048s 37748735s
parted -s /dev/ps3dd unit s mkpart primary linux-swap 37748736s 46137286s
```

Use explicit sectors with the `s` suffix. Petitboot's `parted` mishandles `GiB`
and `%`: `18GiB` produced a 6 GiB partition and `100%` produced 10 GiB.

For the full region table as the hypervisor reports it, see
[region-handling.md](region-handling.md#verified-on-hardware).

## What has and has not been run

The scripts differ in how much hardware exposure they have had. Worth knowing
before trusting one unattended.

| Script | State |
|---|---|
| `kernel-patch.sh` | Run. Produces the kernel that boots. |
| `kernel-config.sh` | Run. Produces the config that boots. |
| `build-image.sh` | Run. Produced the image now on the console. |
| `partition-region.sh` | Run. Produced the current partition table. |
| `write-image.sh` | **Generic form of a verified procedure.** Every write during development used an ad-hoc variant with the hash written into the script. The sequence — unmount, plain-redirect gunzip, sync, md5 against the source, then mount and inspect — is exactly what worked, and the log of one such run is what the content checks are modelled on. This file in that parameterised shape has not itself been run. |
| `build-rootfs.sh` | **Not run.** Written after the fact to make the README followable from a clean machine. The tree it produces is modelled on the one that boots, but it has not built one end to end. |

Neither of the two unrun scripts can damage the console on its own:
`build-rootfs.sh` only touches a directory on the build machine, and
`write-image.sh` stops before the content check if the md5 does not match. The
risk is wasted cycles, not data.
