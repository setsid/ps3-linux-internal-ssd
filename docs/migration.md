# Migration: `ps3da` becomes `ps3dd`

**This is a boot-breaking change. Read it before rebuilding the kernel.**

If you are running the earlier `0002-ps3stor-select-otheros-region.patch` (the
`__fls` hack), your OtherOS region is `/dev/ps3da` and your partitions are
`ps3da1` and `ps3da2`.

After `0002-ps3disk-expose-every-accessible-storage-region.patch`, the same
region is `/dev/ps3dd`, with partitions `ps3dd1` and `ps3dd2` — the names
petitboot has always used for it.

Nothing on the disk changes. Only the device names do. But a kernel that boots
with `root=/dev/ps3da1` will drop to an initramfs prompt with
`ALERT! /dev/ps3da1 does not exist`, and an `fstab` that mounts `/dev/ps3da2`
as swap will fail after boot.

## Do this before you reboot into the new kernel

Both files live on the root partition, which you can reach from petitboot:

```
mount /dev/ps3dd1 /mnt
```

**1. `yaboot.conf`** — the `root=` argument, wherever it appears:

```
-       append="root=/dev/ps3da1 rootdelay=30"
+       append="root=LABEL=ps3root rootdelay=30"
```

**2. `/etc/fstab`**:

```
-/dev/ps3da1  /      ext4  errors=remount-ro  0 1
-/dev/ps3da2  none   swap  sw                 0 0
+LABEL=ps3root  /     ext4  errors=remount-ro,noatime  0 1
+LABEL=ps3swap  none  swap  sw                        0 0
```

**3. Rebuild the initramfs** if it has a device name baked in. Running on the
console, in Debian:

```
update-initramfs -u -k all
```

That is the native equivalent of the `mkinitramfs -o /boot/initrd.img` in
README step 4, which is the chroot form used from the build host.

## Use labels, not device names

The substitutions above use `LABEL=` rather than `ps3dd1`. Labels survive any
future change to region naming, and they are what `scripts/build-image.sh` and
`scripts/partition-region.sh` already set:

```
mke2fs -t ext4 ... -L ps3root
mkswap -L ps3swap /dev/ps3dd2
```

`UUID=` works equally well. Check what you have with `blkid` from the
initramfs shell or from petitboot.

`yaboot` resolves `root=LABEL=` through the initramfs, so the label form needs
a working `initramfs-tools` setup — which you have, since the root filesystem
is ext4 on a driver-provided device. If you would rather not rely on that, use
`root=/dev/ps3dd1` explicitly and keep labels for `fstab`.

## Recovering if you already rebooted

At the petitboot shell:

```
mount /dev/ps3dd1 /mnt
vi /mnt/etc/fstab
vi /mnt/etc/yaboot.conf     # or wherever your boot entry lives
umount /mnt
```

Or boot the new kernel with the argument edited at the petitboot prompt:

```
root=/dev/ps3dd1 rootdelay=30
```

## What else is new

Three regions that were previously invisible now appear, all read-only:

| Device | Region | Contents |
|---|---|---|
| `ps3da` | 0 | the whole physical drive |
| `ps3db` | 1 | GameOS |
| `ps3dc` | 2 | GameOS cache, FAT32 |
| `ps3dd` | 3 | OtherOS — your root filesystem, read-write |

Read-only is the default for everything except the OtherOS region. Mounting
`ps3dc` is a convenient way to move files to and from GameOS:

```
mount -o ro /dev/ps3dc /mnt/gameos-cache
```

To restrict the kernel to the OtherOS region alone, as before:

```
ps3disk.regions=8
```

The name stays `ps3dd` — region selection does not renumber anything. See
`docs/region-handling.md` for the module parameters and the write-protection
policy.
