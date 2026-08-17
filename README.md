# Debian on a PS3 Slim internal drive, kernel 6.4

Notes and patches from getting Debian sid ppc64 booting from the internal
OtherOS region of a PS3 Slim, on a mainline-derived 6.4 kernel, alongside a
working GameOS install.

Existing guides for modern kernels on the PS3 put the root filesystem on
external USB. That avoids two bugs in the PS3 storage path. This documents both
of them and the fixes.

## Hardware

| | |
|---|---|
| Console | PS3 Slim CECH-2503B, NOR flash, UK retail |
| Firmware | Evilnat CFW 4.93 Cobra 8.5 CEX |
| Drive | Kingston SA400S37960G, 960 GB |
| Bootloader | Petitboot (OpenWrt, kernel 2.6.30.10) in VFLASH region 5 |
| Kernel | 6.4.0, Geoff Levand's tree at `98ec4e7cee0f` |
| Userland | Debian sid ppc64, big-endian, ELF ABI v1 |

## The two bugs

### 1. `ps3disk` bounce buffer offset

The one that matters. `ps3disk_scatter_gather()` copies between the driver's
64 KiB bounce buffer and the request's bio vectors. Commit `6e0a48552b8c`
("ps3disk: use memcpy_{from,to}_bvec", 2021) converted it to the newer bvec
helpers and dropped the `offset += size` line in the process.

The result is that every vector in a multi-segment request is copied from
offset zero of the bounce buffer. Single-segment reads are fine. Anything
larger silently returns the first 4 KiB repeated.

Symptoms, all on a filesystem that is provably intact:

- `ext4_check_descriptors: Block bitmap for group N not in group`
- `ext4_mb_generate_buddy: block bitmap and bg descriptor inconsistent`
- `run-init: can't execute '/sbin/init': Permission denied`
- the same binary returning `ENOENT`, then `Not a directory`, on successive boots
- `md5sum` of a partition differing between the 2.6.30 petitboot kernel and 6.4

The nondeterminism is the giveaway: request merging and segmentation vary
between boots, so a different subset of the filesystem is wrong each time.

Fixed upstream by René Rebe in November 2025. This repo carries the same
one-line change as `patches/0001`.

Petitboot is unaffected because 2.6.30 predates the refactor and still has the
original `offset += size`.

### 2. Region selection

Mainline `ps3disk` logs `N accessible regions found. Only the first one will be
used` and takes region 0, which under OtherOS++ is the whole physical drive
rather than the OtherOS region. Under the original Sony OtherOS the hypervisor
exposed only one region, so there was nothing to choose between; CFW exposes
them all.

`patches/0002` selects the highest-numbered region for the disk device, which
is the OtherOS one. Consequence: the region appears as `/dev/ps3da` under
Linux, so partitions are `ps3da1` and `ps3da2` — petitboot still calls the same
region `ps3dd`. Boot arguments and `fstab` must use the Linux names.

This patch is not upstream and is specific to OtherOS++ layouts.

## Kernel configuration

`ps3_defconfig` predates both devtmpfs being standard and systemd existing.
Beyond the defconfig you need:

- `CONFIG_DEVTMPFS` and `CONFIG_DEVTMPFS_MOUNT` — without these `/dev` is never
  populated and the initramfs cannot find root, nor can you type at the
  emergency shell
- USB HID and EHCI/OHCI built in rather than modules, so the initramfs shell
  has a keyboard
- `CONFIG_CGROUPS` and `CONFIG_NAMESPACES` — systemd freezes at
  `Failed to mount API filesystems` without cgroup v2
- `CONFIG_FHANDLE`, `CONFIG_SECCOMP`, `CONFIG_FANOTIFY`, `CONFIG_TMPFS_POSIX_ACL`

`scripts/kernel-config.sh` applies the full set. See `docs/kernel-config.md`.

## Building the root filesystem

Build the image on the development machine, not on the console. Petitboot ships
e2fsprogs 1.41.12 from 2010, which produces group descriptors that the 6.4 ext4
driver rejects outright.

Populate by loop-mounting and copying. `mke2fs -d` produced a filesystem that
passed `e2fsck -fn` cleanly but contained almost nothing under `/usr` — the
directory skeleton was there and the contents were not.

```
mke2fs -t ext4 -b 4096 -O ^metadata_csum,^64bit -L ps3root \
    -F rootfs.img 1048576
mount -o loop rootfs.img /mnt/img
cp -a /srv/ps3root/. /mnt/img/
umount /mnt/img
```

Write it whole from petitboot rather than unpacking a tarball there:

```
gunzip -c rootfs.img.gz > /dev/ps3dd1
sync
```

Verify before booting. `dd if=/dev/ps3dd1 bs=1M count=N | md5sum` against the
source image catches a truncated write, which `dd` piped from `gunzip` will
otherwise do silently — it writes short reads as short blocks unless you pass
`iflag=fullblock`, and petitboot's busybox `dd` has no `iflag`. Use `cat`.

## Layout

Evilnat 4.93 reserves a fixed 46137320 sectors (~22 GiB) for OtherOS regardless
of drive size. Confirmed identical on a 320 GB HDD and a 960 GB SSD.

Old `parted` mishandles `GiB` and `%` arguments — asking for `18GiB` produced a
6 GiB partition. Use explicit sectors:

```
parted -s /dev/ps3dd unit s mklabel gpt
parted -s /dev/ps3dd unit s mkpart primary ext2 2048s 37748735s
parted -s /dev/ps3dd unit s mkpart primary linux-swap 37748736s 46137286s
```

## Repository contents

```
patches/     kernel patches, apply in order
scripts/     build and install helpers
docs/        kernel config notes, troubleshooting log
```

`scripts/` splits into two groups. Those run on the development machine build
the kernel and image; those run at the petitboot shell write to the console and
log their output to the USB stick, since petitboot has no useful way to get
text back off the machine otherwise.

## Things that were not the problem

Recorded because each cost a rebuild cycle:

- filesystem size, block count, or feature flags
- GPT versus MBR
- 64 KiB versus 4 KiB pages
- `noblock_validity` — silences the descriptor check without fixing anything,
  which turns an early clean failure into a later confusing one
- the "Skip all ACL Checks" LV1 patch in Evilnat's CFW settings, in either state
- symlink handling across the usr-merge during `run-init`

## Credit

- René Rebe for the `ps3disk` offset fix, and Christoph Hellwig for reviewing it
- Geoff Levand for the PS3 kernel tree
- glevand for `create_hdd_region.sh` and the OtherOS tools
- Paul Sajna and olin000 for the modern-kernel USB guides this builds on
- kostirez1 for the region layout work on psx-place

## Licence

Kernel patches are GPL-2.0, matching the files they modify. Scripts and
documentation are MIT. See `LICENSE`.
