# Debian on the internal drive of a PS3

Patches, scripts and notes for running Debian sid ppc64 from the internal drive
of a PS3 under OtherOS++, on a 6.4 kernel, alongside a working GameOS install.
Existing guides for modern kernels put the root filesystem on external USB,
which sidesteps two bugs in the PS3 storage path. Both are fixed here. The
result is a machine that boots Debian from the OtherOS region, sees every
storage region the hypervisor exposes, and cannot accidentally write to the
GameOS ones.

> **Upgrading from v1: your root device is renamed and this will stop the
> machine booting.** The OtherOS region moves from `/dev/ps3da` to
> `/dev/ps3dd`, which is what petitboot has always called it. Edit
> `yaboot.conf` and `fstab` *before* rebooting into the new kernel — see
> [docs/migration.md](docs/migration.md).

## What you need

| | |
|---|---|
| Console | A PS3 running OtherOS++ capable CFW. Verified on a Slim CECH-2503B with Evilnat 4.93 Cobra 8.5 CEX |
| Bootloader | Petitboot in VFLASH, and an OtherOS region already created with glevand's `create_hdd_region.sh` |
| Drive | Any internal drive. Verified on a Kingston SA400S37960G, 960 GB |
| Kernel source | Geoff Levand's `ps3-linux` tree at 6.4 |
| Host machine | Linux with `gcc-powerpc64-linux-gnu`, `debootstrap`, `qemu-user-static`, `binfmt-support`, `e2fsprogs` |
| Transfer | A USB stick, to carry the image and scripts to petitboot |

Steps 0 to 6 run on the host machine. Steps 7, 8 and 9 happen at the console —
7 and 8 at the petitboot shell, 9 is the reboot itself.

**Steps 0 to 4 and 7 are done once. Steps 5, 6, 8 and 9 are the rebuild loop.**
Once the kernel is installed and the region is partitioned, iterating means
build the image, copy it to the stick, write it, reboot — and nothing above
that needs re-reading.

Which loop depends on what you changed. A userland change is 5, 6, 8, 9. A
kernel change is 3, 4, 5, 6, 8, 9 — steps 3 and 4 first, or step 5 packages a
tree that still contains the old `vmlinux` and you spend forty minutes writing
and booting the kernel you were trying to replace.

## Steps

Every command below runs from the root of this repository, so script paths are
relative to it. `~/ps3-linux` is the kernel tree from step 1 — adjust it
throughout if you clone somewhere else.

**0. Build the Debian root filesystem.** *(once)*

```
sudo ./scripts/build-rootfs.sh /srv/ps3root
```

This debootstraps Debian sid `ppc64` from Debian *ports*, installs the packages
needed to boot and administer the machine, writes `fstab` and `yaboot.conf` by
label, and installs the udev rule described below. Everything after this
assumes the tree exists at `/srv/ps3root`.

It produces the userland only. No kernel, no modules, no initrd — those are
step 4, which is the one place in this sequence that installs a kernel. It
depends on nothing above it, so it can run before, after or alongside steps 1
to 3.

**This step has not been run end to end.** It was written after the fact so the
sequence is followable from a clean machine; steps 1 to 9 are the ones that
were executed. It is modelled on the tree that boots, but treat it as untested
and check its output before relying on it.

**You set your own passwords.** The script prompts twice during the run, once
for root and once for the user it creates. **This repository ships no
credentials of any kind** — no passwords, no keys, no accounts. Nothing you
install here inherits anyone else's, and nothing is defaulted.

**1. Get the kernel source.** *(once)*

```
git clone https://git.kernel.org/pub/scm/linux/kernel/git/geoff/ps3-linux.git ~/ps3-linux
```

**2. Apply both patches.** *(once)*

```
./scripts/kernel-patch.sh ~/ps3-linux
```

The script prints the patched code back so you can see it landed. It also fails
if `drivers/ps3/ps3stor_lib.c` still carries the withdrawn v1 hack.

**On a newer kernel, `0001` may do nothing, and that is correct.** René Rebe's
bounce buffer fix was posted upstream in November 2025. It is absent at `v6.17`,
so anything from roughly 6.18 onward already carries it. Check rather than
assume:

```
grep -n 'offset += bvec.bv_len' drivers/block/ps3disk.c
```

Nothing back means the tree needs `0001`. `kernel-patch.sh` runs the same test
and skips the patch when the line is already there, reporting
`0001 bounce buffer offset: already applied`. `0002` is not upstream and is
always needed.

**3. Configure and build the kernel.** *(once)*

```
make -C ~/ps3-linux ARCH=powerpc ps3_defconfig
./scripts/kernel-config.sh ~/ps3-linux
make -C ~/ps3-linux ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- -j$(nproc)
```

A bare `make`, not `make vmlinux`. The bare target builds `vmlinux` and the
modules together; `vmlinux` alone skips modules entirely and step 4 then has
nothing to install.

Run `kernel-config.sh` once, after `ps3_defconfig` — re-running the defconfig
discards it. It adds devtmpfs, cgroups, namespaces and built-in USB HID, none
of which `ps3_defconfig` has and all of which a systemd userland needs. See
[docs/kernel-config.md](docs/kernel-config.md).

It also turns `CONFIG_LOCALVERSION_AUTO` off, which matters: a patched tree
otherwise builds as `-dirty`, `/lib/modules` stops matching `uname -r`, and no
module loads. `.scmversion` does not fix this — kbuild dropped it in 5.19. A
trailing `+` can still appear when HEAD is not on an exact tag; that is
harmless as long as `modules_install` runs after the final build.

**4. Install the kernel and modules into the tree.** *(once)*

```
powerpc64-linux-gnu-strip -s -o /tmp/vmlinux-stripped ~/ps3-linux/vmlinux
sudo cp /tmp/vmlinux-stripped /srv/ps3root/boot/vmlinux
sudo make -C ~/ps3-linux ARCH=powerpc CROSS_COMPILE=powerpc64-linux-gnu- \
    INSTALL_MOD_PATH=/srv/ps3root modules_install
sudo chroot /srv/ps3root mkinitramfs -o /boot/initrd.img <kernel release>
```

The strip is not optional. Unstripped `vmlinux` is about 143 MB; stripped it is
about 19 MB.

This is the only step that puts a kernel into the tree. Re-run it whenever you
rebuild the kernel, before step 5, or the image will carry the previous one.

`<kernel release>` is what `make -s kernelrelease` prints in the kernel tree.
`kernel-config.sh` prints it too, at the end of step 3. It has to match the
directory under `/lib/modules` exactly, which is what turning
`CONFIG_LOCALVERSION_AUTO` off in step 3 is protecting: a mismatch means
`mkinitramfs` builds an initrd with no modules in it.

Copy it verbatim, including any trailing `+` — that character is part of the
directory name. On the console here `uname -r` reports
`6.4.0-g98ec4e7cee0f+`, with the plus, and that is the directory name under
`/lib/modules`. `ls /srv/ps3root/lib/modules` after `modules_install` is the
check that settles it.

The initrd has to be regenerated on every kernel rebuild, alongside the
`vmlinux` copy. Miss it and step 5 packages a new kernel with an initrd built
for the old one.

The initrd is also why the emergency shell has a keyboard. `mkinitramfs` did
not pull USB HID or the host controllers in, so `kernel-config.sh` builds them
into the kernel instead. An initramfs prompt you cannot type at is useless on a
machine whose only console is a television.

Watch the total size. About 19 MB of `vmlinux` plus about 15 MB of initrd is
34 MB that petitboot has to kexec into 256 MB of RAM, alongside itself.

**5. Build the image.** *(rebuild loop)*

```
sudo mkdir -p /mnt/img
sudo mke2fs -t ext4 -b 4096 -O ^metadata_csum,^64bit -L ps3root \
    -F /tmp/ps3root4g.img 1048576
sudo mount -o loop /tmp/ps3root4g.img /mnt/img
sudo cp -a /srv/ps3root/. /mnt/img/
sudo umount /mnt/img
md5sum /tmp/ps3root4g.img
```

Keep that md5; step 8 needs it.

Populate with `cp -a`, never `mke2fs -d`. A `-d` built image passed `e2fsck -fn`
cleanly and contained an almost empty `/usr` — one directory in it. That cost
hours, and it fails at `run-init` rather than at build time.

Build on the host, not on the console: petitboot's `mke2fs` is from 2010 and
writes group descriptors the 6.4 ext4 driver rejects outright.

1048576 blocks of 4 KiB is 4 GiB. The region holds 18 GiB, but 4 is enough for
a 1.4 GiB tree and it quarters both the write and the verify. Grow it later
from inside Debian with `resize2fs`.

`scripts/build-image.sh` is the same sequence scripted, with an `e2fsck` pass
at the end.

**6. Copy it to the USB stick.** *(rebuild loop)*

```
sudo mkdir -p /mnt/stick
sudo mount -t drvfs D: /mnt/stick
sudo sh -c 'gzip -1 -c /tmp/ps3root4g.img > /mnt/stick/ps3root4g.img.gz'
sudo cp scripts/partition-region.sh scripts/write-image.sh /mnt/stick/
sudo umount /mnt/stick
```

The two petitboot scripts go on the stick alongside the image — steps 7 and 8
run them from there.

`gzip -1` deliberately. The image is mostly zeroes, so it comes out around
525 MB at any level, and `-1` is much faster. `drvfs` is the WSL driver for
mounting a Windows drive letter; on a native Linux host, mount the stick
however you normally would.

**7. Partition the OtherOS region.** *(once)* At the petitboot shell:

```
sh /tmp/*/mnt/*/partition-region.sh
```

Only needed once, or again if the region is recreated. It is not part of the
rebuild loop — writing an image does not disturb the partition table.

Sizes are in raw sectors throughout, because petitboot's `parted` mishandles
`GiB` and `%` arguments — asking for `18GiB` produced a 6 GiB partition.

**8. Write and verify the image.** *(rebuild loop)* Still at petitboot, with the
md5 from step 5:

```
sh /tmp/*/mnt/*/write-image.sh <md5>
```

The image name defaults to `ps3root4g.img.gz`, which is what step 5 produces,
so it only needs passing when the file is called something else — a second
argument, before the optional size in MiB:

```
sh /tmp/*/mnt/*/write-image.sh <md5> ps3root18g.img.gz 18432
```

Pass the size too when the image is not 4 GiB, or the hash check only verifies
the first 4096 MiB of it.

It writes with a plain redirect rather than piping into `dd`, because busybox
`dd` has no `iflag=fullblock` and silently truncates a gzip stream, then reads
the region back and compares the hash before it will go on to check the
contents. Both petitboot scripts log to the USB stick, since getting text off
the console otherwise means photographing a television.

**9. Reboot and select Debian.** *(rebuild loop)* Check `dmesg | grep ps3disk`
on first boot; the line to look for is `OtherOS region is region 3`. Expected
output is in
[docs/region-handling.md](docs/region-handling.md#verified-on-hardware).

## Module parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ps3disk.regions=<mask>` | `0` | Which regions to expose. `0` is all accessible. Bit *n* is region *n*. |
| `ps3disk.writable=<mask>` | `0` | Regions to force read-write, in addition to the OtherOS region. |
| `ps3disk.otheros_rw=<0\|1>` | `Y` | Whether the detected OtherOS region is writable. |

```
ps3disk.regions=8       # only the OtherOS region; still named ps3dd
ps3disk.otheros_rw=0    # everything read-only, for a rescue boot
```

Region selection never renumbers anything, so a region keeps its name whichever
others are exposed.

## The udev rule

`scripts/61-ps3-persistent-storage.rules` is not part of the kernel patches and
is needed on any PS3 running a modern systemd, patched kernel or not.

systemd's `60-persistent-storage.rules` matches `sd*`, `sr*`, `vd*`, `mmcblk*`,
`cciss*` and `pmem*`. PS3 block devices are `ps3d*` and match none of them, so
the `blkid` builtin never runs, no `ID_FS_*` properties are set, and `/dev/disk`
is never created at all. Anything resolved by label or UUID through udev then
fails.

Root still boots, which is what makes it confusing to diagnose — the initramfs
resolves `root=LABEL=` itself, without udev. But the swap unit systemd
generates from `fstab` waits on `/dev/disk/by-label/ps3swap`, nothing creates
it, and it times out after 90 seconds. Swap never activates.

`build-rootfs.sh` installs the rule to `/etc/udev/rules.d/`. With it in place,
`/dev/disk/by-label/ps3root` and `ps3swap` both appear and `blkid` returns full
properties for every region.

### Upstream work

The proper fix is upstream: systemd's `60-persistent-storage.rules` should
match `ps3d*` alongside the other block device patterns. Until it does, every
PS3 running systemd needs a local rule. This one is deliberately numbered 61 so
it runs after the file it supplements, and is written to be droppable once
upstream catches up.

## Verified state

What has actually run on hardware, so nobody assumes more testing than has
happened:

| | |
|---|---|
| `patches/0001`, `patches/0002` | Booted. Region detection, write protection, naming, concurrent reads across three regions — all confirmed, see [docs/region-handling.md](docs/region-handling.md#verified-on-hardware) |
| `61-ps3-persistent-storage.rules` | Confirmed: `/dev/disk/by-label` populated, `blkid` working |
| `kernel-patch.sh`, `kernel-config.sh` | Run. Produced the kernel that boots |
| `build-image.sh`, `partition-region.sh` | Run. Produced the image and partition table now on the console |
| `write-image.sh` | Generic form of a verified procedure. Every development write used an ad-hoc variant with the hash written in; this parameterised file has not itself been run |
| `build-rootfs.sh` | **Not run.** Written afterwards so the steps above are followable from a clean machine. Modelled on the tree that boots, but never built one end to end |

Neither unrun script can damage the console on its own. `build-rootfs.sh` only
writes to a directory on the build machine, and `write-image.sh` stops before
the content check if the hash does not match. The risk is a wasted cycle.

## How it works

### Bug 1: the bounce buffer offset

`ps3disk_scatter_gather()` copies between the driver's 64 KiB bounce buffer and
the request's bio vectors. Commit `6e0a48552b8c` ("ps3disk: use
memcpy_{from,to}_bvec", 2021) converted it to the newer bvec accessors and
dropped the `offset += size` line in the process. Every vector in a
multi-segment request is therefore copied to or from offset zero, corrupting
all but the first.

Single-segment requests are fine, so the superblock reads correctly and
anything larger returns repeated data. It presents as ext4 group descriptor
errors, binaries that exist but will not execute, and a different errno on each
boot — the nondeterminism is the giveaway, since request segmentation varies
between boots. `patches/0001` restores the line.

Petitboot is unaffected: 2.6.30 predates the refactor. Worth knowing before
moving to a newer kernel, upstream `ps3disk.c` at `v6.17` still has this bug —
the fix postdates that release, so check for `offset += bvec.bv_len` in
whatever tree you move to rather than assuming.

### Bug 2: region selection

Mainline `ps3disk` logs `N accessible regions found. Only the first one will be
used` and takes region 0, which under OtherOS++ is the whole physical drive
rather than the OtherOS region. Under Sony's original OtherOS the hypervisor
exposed one region and there was nothing to choose between; CFW exposes them
all.

`patches/0002` gives each accessible region its own block device instead of
choosing between them, matching petitboot:

| Device | Region | Contents | Default |
|---|---|---|---|
| `ps3da` | 0 | whole physical drive | read-only |
| `ps3db` | 1 | GameOS, UFS2 | read-only |
| `ps3dc` | 2 | GameOS cache, FAT32 | read-only |
| `ps3dd` | 3 | OtherOS | read-write |

Everything except the OtherOS region is read-only by default. Region 1 is
roughly 870 GB of games and the filesystem GameOS needs in order to boot at
all; exposing it read-write one letter away from the root filesystem is not
worth the convenience, and a partially written GameOS region means a full
reinstall. The OtherOS region is identified as the highest-numbered accessible
region that is neither region 0 nor the size of the whole drive.

Because the other regions are read-only, mounting them is safe to do casually.
The FAT32 cache region is a useful file transfer path between the two systems:

```
mount -o ro /dev/ps3dc /mnt/gameos-cache
```

`ps3db` is not mountable — `CONFIG_UFS_FS` is off deliberately, since Linux UFS
support is read-only and patchy and there is nothing useful to read there.

The patch is confined to `drivers/block/ps3disk.c`. It needs no change to
`ps3stor_lib.c`, `asm/ps3stor.h`, `ps3rom` or `ps3flash`, because `ps3disk`
computes its region id locally and never calls `ps3stor_read_write_sectors()`.
It replaces the v1 `__fls` hack, which is withdrawn rather than superseded.

Not upstream, and specific to OtherOS++ layouts. The design rationale, the
serialisation argument, the write-protection failure modes and the hardware
verification are in
[docs/region-handling.md](docs/region-handling.md).

## Repository contents

```
patches/     kernel patches, apply in order
scripts/     build and install helpers
docs/        design notes, kernel config, troubleshooting log
```

`scripts/` splits in two. Those run on the host build the kernel and image;
those run at the petitboot shell write to the console and log their output to
the USB stick.

| Document | |
|---|---|
| [docs/migration.md](docs/migration.md) | v1 to v2: `ps3da` becomes `ps3dd`. Read before rebuilding. |
| [docs/region-handling.md](docs/region-handling.md) | Why `patches/0002` is built the way it is, and what was verified. |
| [docs/kernel-config.md](docs/kernel-config.md) | Config options beyond `ps3_defconfig`, and why each is needed. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms and causes, in the order they appear during a build. |

## Credit

Written by setsid. `patches/0002`, the documentation and the scripts are mine;
the work below is other people's and is credited because this builds on it.

- René Rebe for the `ps3disk` offset fix, and Christoph Hellwig for reviewing it
- T2 SDE for
  `architecture/powerpc64/package/linux/0010-ps3stor-multiple-regions.patch`,
  which established that the answer is one block device per accessible region
  rather than a better choice of single region. `patches/0002` takes that idea
  and differs in the details — see `docs/region-handling.md`
- Geoff Levand for the PS3 kernel tree
- glevand for `create_hdd_region.sh` and the OtherOS tools
- Paul Sajna and olin000 for the modern-kernel USB guides this builds on
- kostirez1 for the region layout work on psx-place

## Licence

Kernel patches are GPL-2.0, matching the files they modify. Scripts and
documentation are MIT. See [LICENSE](LICENSE).
