# Region handling in `ps3disk`

Design notes for `patches/0002-ps3disk-expose-every-accessible-storage-region.patch`.

This is the reasoning behind the patch, including the parts that were
considered and rejected. Testing on this hardware costs about 40 minutes per
cycle with no interactive debugger, so the argument for why each piece is
correct is written down rather than discovered by experiment.

## The problem

LV1 divides the internal drive into regions and tells the guest LPAR which of
them it may reach. `ps3stor_probe_access()` reads sector 0 of each region in
turn and records the ones that succeed in `dev->accessible_regions`.

Under Sony's OtherOS exactly one region was reachable, so
`dev->region_idx = __ffs(dev->accessible_regions)` was unambiguous and
`ps3disk` could expose one block device per hypervisor device.

OtherOS++ skips the ACL check and makes every region reachable. On a PS3 Slim
running Evilnat 4.93 that is four:

| Region | Contents | Size on a 960 GB SSD |
|---|---|---|
| 0 | the whole physical drive | 915 GiB |
| 1 | GameOS `dev_hdd0`, UFS2 | ~870 GB |
| 2 | GameOS cache, FAT32 | ~1 GB |
| 3 | OtherOS | 46137320 sectors, ~22 GiB |

Mainline keeps region 0, logs `4 accessible regions found. Only the first one
will be used`, and the region the machine boots from is unreachable. The
previous patch in this repository changed `__ffs` to `__fls`, which keeps
region 3 and loses the other three.

## Scope: why this stays inside `ps3disk.c`

T2 SDE's `0010-ps3stor-multiple-regions.patch` adds a `region_idx` parameter to
the exported `ps3stor_read_write_sectors()`, which forces changes to
`arch/powerpc/include/asm/ps3stor.h` and to every caller.

That is not necessary. `ps3disk` does not call `ps3stor_read_write_sectors()`.
`ps3disk_submit_request_sg()` computes the region id itself and calls
`lv1_storage_read()` / `lv1_storage_write()` directly. Inside `ps3stor_lib.c`
the only caller of `ps3stor_read_write_sectors()` is `ps3stor_probe_access()`,
which uses `dev->region_idx` as a scratch variable while probing. The external
callers are `ps3rom` and `ps3flash`, neither of which wants multi-region
behaviour — `ps3flash` in particular must keep taking the first accessible
region.

So the whole change lives in `drivers/block/ps3disk.c`. `ps3stor_lib.c`,
`asm/ps3stor.h`, `ps3rom` and `ps3flash` are untouched, and
`dev->region_idx` keeps its existing meaning for everyone who still uses it.
`ps3disk` simply stops reading it.

A consequence worth stating: the `__fls` hack is not merely superseded, it is
withdrawn. `ps3stor_lib.c` goes back to pristine, so `ps3flash` behaves as
upstream intends again.

## Region identity: private data, not minor arithmetic

T2 recovers the region in the request path with

```c
MINOR(disk_devt(req->q->disk)) / PS3DISK_MINORS
```

That works, but it couples the request path to the minor allocation scheme.
It breaks quietly if `PS3DISK_MINORS` changes, if a disk is ever allocated a
non-contiguous minor range, or if the letter allocation stops being a simple
multiple of the minor count — which it does here, because names are now
allocated per region rather than per device.

Instead there is one small structure per exposed region:

```c
struct ps3disk_region_priv {
	struct ps3_storage_device *dev;
	struct gendisk *gendisk;
	unsigned int region_idx;	/* Index into dev->regions[] */
	unsigned int devidx;		/* Name letter and first minor */
};
```

It is reachable from both `queue->queuedata` and `gendisk->private_data`, so
`ps3disk_queue_rq()` gets the region by dereferencing a pointer it already has.
The device-wide state stays in `struct ps3disk_private`, which now carries a
flexible array of these, one per region, in the same allocation:

```c
priv = kzalloc(struct_size(priv, disk, dev->num_regions), GFP_KERNEL);
```

`dev->num_regions` is small — four on this hardware — and
`struct ps3disk_region_priv` is 32 bytes, so the upper-bound allocation costs
around 128 bytes and saves having to know the exposed count before
`ps3stor_setup()` has run. That matters on a 256 MB machine only in the sense
that it is nothing.

## Serialisation across regions

This is the part most likely to be wrong, so here is the full argument.

### The constraint

LV1 accepts one outstanding command per **device**, not per region. The device
has one `dev->tag`, one 64 KiB bounce buffer, one interrupt, and the driver
keeps one `priv->req`. Several block devices now feed one hypervisor device,
and each has its own request queue that can dispatch concurrently.

### The mechanism: one tag set, queue depth one

Every region queue is created from a single `blk_mq_tag_set` allocated with
`blk_mq_alloc_sq_tag_set(&priv->tag_set, &ps3disk_mq_ops, 1, ...)`.

The guarantee comes from how blk-mq assigns tags. In `blk_mq_init_hctx()`:

```c
hctx->tags = set->tags[hctx_idx];
```

and again in `blk_mq_map_swqueue()`. `set->tags` belongs to the tag set, not to
the request queue, so every queue built from one tag set has its hardware
context pointing at *the same* `struct blk_mq_tags`, and therefore the same
sbitmap. With `queue_depth = 1` that bitmap has exactly one bit.

That one tag is the device-wide permit to use the bounce buffer. A request
holds it from `blk_mq_start_request()` until `blk_mq_end_request()`, which the
interrupt handler calls only after the hypervisor command has completed and,
for a read, after `ps3disk_scatter_gather()` has copied the data out. No
second request can enter `queue_rq` on any queue in the meantime, because
there is no second tag.

This is not a novel arrangement. It is exactly how SCSI serialises several
LUNs behind a host adapter with `can_queue == 1`: one tag set per host, one
request queue per LUN.

Three details that could have broken it, checked against the 6.4 source:

- **Adding queues later.** `blk_mq_add_queue_tag_set()` sets
  `BLK_MQ_F_TAG_QUEUE_SHARED` on the transition from one queue to two and
  freezes the existing queues while it does so. Disks are created one at a
  time in a loop, and the block layer is designed for this — SCSI adds LUNs to
  a live host constantly.
- **Fair sharing.** `hctx_may_queue()` limits each queue to
  `max(depth / active_queues, 4)` requests. With `depth == 1` that evaluates
  to 4, so it never becomes more restrictive than the one-bit bitmap. It
  cannot let a second request through either; the bitmap is the binding
  constraint.
- **Flush requests.** With an elevator or without, `flush_rq` borrows the tag
  or internal tag of the request that triggered it rather than taking a second
  one, and the flush state machine sequences preflush, data and postflush.
  Still one command in flight.

### The backstop

`ps3disk_queue_rq()` still checks `priv->req` under `priv->lock` and returns
`BLK_STS_DEV_RESOURCE` if it is set, with a `dev_err_once()`.

This should be unreachable. It is there because the failure mode if the
reasoning above is wrong is silent bounce buffer corruption — the same class of
bug as the offset regression that patch 0001 fixes, and just as hard to
attribute. Deferring a request costs 3 ms and one log line; getting it wrong
costs another 40-minute cycle chasing filesystem corruption.

Returning `BLK_STS_DEV_RESOURCE` after `blk_mq_start_request()` is legal:
`blk_mq_handle_dev_resource()` calls `__blk_mq_requeue_request()`, which
releases the driver tag and resets `rq->state` to `MQ_RQ_IDLE` for a started
request. `virtio_blk` does the same thing.

### Completion

The queue with work waiting is not necessarily the one that just finished, so
the interrupt handler runs all of them:

```c
for (i = 0; i < priv->num_disks; i++)
	blk_mq_run_hw_queues(priv->disk[i].gendisk->queue, true);
```

With the shared tag set this is mostly redundant — freeing the tag wakes a
waiter through the sbitmap waitqueue — but it is what makes the backstop path
recover promptly instead of waiting out the 3 ms retry timer. `async = true`,
so nothing is dispatched inline from interrupt context. Four iterations of a
cheap call in the completion path is not a cost worth optimising.

`priv->num_disks` is only written in probe and remove, when no I/O can be in
flight, so reading it unlocked in the handler is safe.

### Alternatives rejected

**Per-queue tag sets plus a device-wide busy flag.** Every collision would go
through the `BLK_STS_DEV_RESOURCE` path and its 3 ms delay, and the block
layer would have no idea the queues are related, so it would keep dispatching
into a driver that keeps refusing. The shared tag set instead makes the block
layer's own admission control do the work.

**Stopping the other queues on submit and starting them on completion.**
`blk_mq_stop_hw_queues()` adds a second piece of state that has to stay
consistent with `priv->req` across every error path, and stop/start races are
a known source of hangs. No benefit over letting the tag do it.

**A device-wide mutex around submission.** Cannot sleep in `queue_rq`, and it
would serialise the submission call rather than the whole command lifetime,
which is the thing that actually needs serialising.

### Starvation

The sbitmap waitqueue is roughly FIFO, so a busy region can delay another but
cannot deadlock it — completion is driven entirely by the hardware interrupt,
and no queue waits on another queue's progress. In practice the OtherOS region
carries essentially all the traffic.

## Write protection

### The policy

Every exposed region is read-only unless something explicitly says otherwise.
The one automatic exception is the region identified as the OtherOS region.

`set_disk_ro(gendisk, 1)` is called **before** `device_add_disk()`, so the
first partition scan and any udev probe already see a read-only device.
Partitions inherit it: `bdev_read_only()` checks `get_disk_ro()` on the parent
disk, and `bio_check_ro()` rejects writes in `submit_bio_noacct()`.

### Why the default matters this much

Region 1 on this console is roughly 870 GB of games and the UFS2 filesystem
GameOS needs in order to boot at all. Region 0 contains it. If they are
exposed as ordinary read-write block devices one letter away from the root
filesystem, a mistyped `mkfs` or `dd` target destroys them, and a partially
written GameOS region means `Restore PS3 System` and a full reinstall.

T2's patch exposes them read-write. That is the one part of its approach not
carried over.

### Identifying the OtherOS region

The rule is: **the highest-numbered exposed region that is not region 0 and
does not span the whole drive.**

```c
for_each_set_bit(i, &exposed, dev->num_regions) {
	if (!i)
		continue;			/* whole drive by convention */
	if (ps3disk_region_is_whole_drive(dev, priv, i))
		continue;
	found = i;
}
```

`ps3disk_region_is_whole_drive()` uses two independent signals:

1. `dev->regions[i].size * blocking_factor >= priv->raw_capacity`, where
   `raw_capacity` comes from ATA IDENTIFY. This is the authoritative test.
2. `dev->regions[i].id == 0`. LV1 uses region id 0 to address the whole
   device, which is why `ps3rom` hardcodes `accessible_regions = 1` and uses
   `regions[0]`. This is the fallback when IDENTIFY failed and `raw_capacity`
   is zero.

Plus the flat refusal to ever auto-select index 0.

Three overlapping guards for one decision is deliberate. They are cheap, they
are independent, and the thing they protect against is unrecoverable.

### Is "highest-numbered" sound?

It is sound on the layout it was written for and degrades in a stated
direction elsewhere.

| Layout | Result | Correct? |
|---|---|---|
| OtherOS++, regions 0–3, OtherOS created last | picks 3 | yes |
| Sony OtherOS, one region visible, id ≠ 0, smaller than the drive | picks it | yes |
| CFW with ACL skipped but no OtherOS region created | picks the cache region, or nothing | **no** |
| Only region 0 reachable | picks nothing, all read-only | yes |
| IDENTIFY failed | falls back to the id test; may pick nothing | safe |
| Two custom regions | picks the higher one | probably; check the log |

The third row is the honest failure. If there is no OtherOS region, the
highest non-whole-drive region is the GameOS cache, and it would be exposed
read-write. The mitigation is that this configuration cannot boot Linux from
the internal drive in the first place — there is nothing to boot from — and
the cache region is FAT32 scratch space rather than the UFS2 filesystem GameOS
needs. It is still worth knowing about.

The asymmetry drives the whole design: guessing too permissively can destroy
data with no warning, guessing too restrictively produces a read-only root
filesystem, a failed boot, and a log line saying exactly what happened. The
second is a reboot with a different kernel argument.

### Overriding it

```
ps3disk.otheros_rw=0                 # nothing is writable by default
ps3disk.otheros_rw=0 ps3disk.writable=4    # region 2 is the OtherOS region
ps3disk.writable=0xf                 # everything read-write; be certain
```

`writable=` is masked with the exposed set, so it cannot resurrect a region
that `regions=` excluded.

## Naming

Petitboot's patched 2.6.30 kernel exposes all four regions and names them by
region index. Matching that means a device path means the same thing in the
bootloader and in the booted system, which is worth more than it sounds — the
`ps3da` versus `ps3dd` mismatch introduced by the previous patch cost hours.

| Region | Name | Contents |
|---|---|---|
| 0 | `ps3da` | whole physical drive |
| 1 | `ps3db` | GameOS |
| 2 | `ps3dc` | GameOS cache |
| 3 | `ps3dd` | OtherOS |

The existing `ps3disk_mask` allocates one letter per hypervisor device. It now
allocates a contiguous run of letters per device, one per region index:

```c
span = __fls(exposed) + 1;
devidx = bitmap_find_next_zero_area(&ps3disk_mask, PS3DISK_MAX_DISKS,
				    0, span, 0);
bitmap_set(&ps3disk_mask, devidx, span);
```

and region `r` takes letter `devidx + r`.

Reserving the whole span rather than one letter per *disk* is the point. It
means the name follows the region index, so `ps3disk.regions=8` still gives
`ps3dd` and not `ps3da`. A selection parameter that renamed things would
recreate exactly the trap it is meant to avoid.

`ps3disk_remove()` no longer reverses the mapping through
`MINOR(disk_devt(...)) / PS3DISK_MINORS`. `priv->devidx_base` and
`priv->devidx_span` are stored at probe time and `bitmap_clear()` releases
them, which is both simpler and correct when the span is not one.

`PS3DISK_MAX_DISKS` stays at 16, and `bitmap_find_next_zero_area()` returns a
value past the end on failure, so `devidx + span > PS3DISK_MAX_DISKS` is the
failure test.

## Lifecycle

### Probe

1. Reject `blk_size < 512`, and `num_regions` of zero or more than
   `BITS_PER_LONG` — `accessible_regions` is an `unsigned long`, so that is
   already an implicit limit in `ps3stor_lib.c`.
2. Allocate `priv` sized for `num_regions` regions.
3. Bounce buffer, `ps3stor_setup()`, `ps3disk_identify()`. The identify
   return value is now checked; mainline discards it. A failure is not fatal
   but is logged, because it degrades the whole-drive test.
4. Compute the exposed set from `accessible_regions` and `regions=`. Fail with
   `-ENODEV` if it is empty.
5. Identify the OtherOS region and compute the writable set.
6. Log every region that is not exposed and why.
7. Reserve the letter span.
8. Allocate the shared tag set.
9. `ps3disk_add_region()` per exposed region.

### Partial failure

`ps3disk_add_region()` either fully succeeds and increments
`priv->num_disks`, or cleans up its own `gendisk` and returns an error without
touching the count. The probe unwind then only has to deal with disks that are
fully live:

```
fail_del_disks:   ps3disk_del_disks(priv); blk_mq_free_tag_set()
fail_free_devidx: bitmap_clear()
fail_teardown:    ps3stor_teardown()
fail_free_bounce: kfree(dev->bounce_buf)
fail_free_priv:   kfree(priv); set_drvdata(NULL)
```

Each label is reachable only after the step it undoes has succeeded, so a
failure in region 2 after region 1 succeeded unwinds region 1 and nothing
else.

### Teardown

`ps3disk_del_disks()` deletes every disk before releasing any of them:

```c
for (i = 0; i < priv->num_disks; i++)
	del_gendisk(priv->disk[i].gendisk);
for (i = 0; i < priv->num_disks; i++)
	put_disk(priv->disk[i].gendisk);
```

Interleaving them would leave one region's queue live and able to submit while
another was being torn down. Doing all the `del_gendisk()` calls first drains
and quiesces every queue before anything is freed, so by the time the tag set
goes away nothing can reference it.

`ps3disk_sync_cache()` fires once per device, after all the disks are gone.
It has to: it goes through `ps3stor_send_command()`, which uses `dev->done`
and `dev->tag` and depends on `priv->req` being NULL so that the interrupt
handler takes the non-block-layer path. Calling it per region would issue
`LV1_STORAGE_ATA_HDDOUT` several times for one physical write cache, and would
do it while other regions could still be submitting.

`ps3disk_remove()` is registered as both `.remove` and `.shutdown`. It now
returns early if `drvdata` is NULL, so being called twice is a no-op rather
than a double free. Mainline has the same exposure; it is one line to close.

## First boot

For the output this actually produces on hardware, see
[Verified on hardware](#verified-on-hardware) below. What to check, in order:

- **`OtherOS region is region 3`.** If it names a different region, or says
  `no OtherOS region found`, the heuristic disagreed with the layout. The
  per-region lines above it say why. Fix with
  `ps3disk.otheros_rw=0 ps3disk.writable=<bit>`.
- **`ps3dd` is `read-write`** and the others are `read-only`.
- **`ps3dd` is about 22527 MiB.** The Evilnat OtherOS region is 46137320
  sectors regardless of drive size. A different figure means the region
  indices are not what this document assumes.
- **`4 of 4 regions`.** Fewer means `regions=` excluded some, or the
  hypervisor refused access; the `not selected` / `not accessible` lines
  distinguish the two.
- **`device busy, deferring request`** must never appear. If it does, the
  shared-tag argument above is wrong on this kernel and the backstop is the
  only thing preventing corruption. Say so before trusting the filesystem.

The logging is `dev_info` rather than `dev_dbg` on purpose. It is roughly six
lines once at boot, and it is the only feedback available without a debugger.

## Verified on hardware

| | |
|---|---|
| Console | PS3 Slim CECH-2503B, NOR flash |
| Firmware | Evilnat CFW 4.93 Cobra 8.5 CEX |
| Drive | Kingston SA400S37960G, 960 GB, internal |
| Kernel | 6.4.0-g98ec4e7cee0f+ |
| Userland | Debian sid ppc64, big-endian |

```
[    3.096303] ps3disk sb_01: ps3stor_probe_access:115: 4 accessible regions found. Only the first one will be used
[    3.096859] ps3disk sb_01: First accessible region has index 0 start 0 size 1875385008
[    3.097972] ps3disk sb_01: OtherOS region is region 3
[    3.099869] ps3disk sb_01: ps3da: region 0 id 0 start 0 size 1875385008 (915715 MiB) read-only
[    3.163960] ps3disk sb_01: ps3db: region 1 id 1 start 524320 size 1824529056 (890883 MiB) read-only
[    3.169984] ps3disk sb_01: ps3dc: region 2 id 2 start 1825053376 size 4194296 (2047 MiB) read-only
[    3.176785] ps3disk sb_01: ps3dd: region 3 id 3 start 1829247680 size 46137320 (22527 MiB) read-write
[    3.193764] ps3disk sb_01: KINGSTON SA400S37960G (915715 MiB total), 4 of 4 regions
```

```
NAME     MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
ps3da    254:0    0 894.3G  1 disk
ps3db    254:16   0   870G  1 disk
ps3dc    254:32   0     2G  1 disk
ps3dd    254:48   0    22G  0 disk
├─ps3dd1 254:49   0    18G  0 part /
└─ps3dd2 254:50   0     4G  0 part
```

What this confirms:

- **The OtherOS region is detected correctly.** Region 3, the highest-numbered
  accessible region that does not span the whole drive. Region 0 is rejected on
  both counts — `id 0`, and `size 1875385008` equal to the drive's full sector
  count.
- **Write protection is applied to the other three.** The `RO` column reads
  `1 1 1 0`, and so does `cat /sys/block/ps3d{a,b,c,d}/ro`.
- **Names match petitboot.** `ps3da` through `ps3dd` for regions 0 to 3, so a
  device path means the same thing in the bootloader and in the booted system.
- **The region layout is as documented.** Regions are contiguous —
  `524320 + 1824529056 = 1825053376`, and `1825053376 + 4194296 = 1829247680` —
  and the OtherOS region is the expected 46137320 sectors.
- **Root mounted by `LABEL=`**, on `ps3dd1`, with `ps3dd2` as swap.
- **`device busy, deferring request` never appeared.** The backstop in
  `ps3disk_queue_rq()` did not fire across boot, partition scan, `systemd-udevd`
  probing four disks concurrently, and normal use. The shared-tag serialisation
  argument holds on real hardware.

### Write protection is enforced, not cosmetic

`set_disk_ro()` is not advisory. The block layer rejects the write in
`bio_check_ro()` before it reaches the driver:

```
# dd if=/dev/zero of=/dev/ps3db bs=512 count=1
dd: error writing '/dev/ps3db': Operation not permitted
0 bytes copied
```

Zero bytes written. That is the guard between a mistyped device letter and a
GameOS reinstall.

### Concurrent reads across regions

Three regions read simultaneously through the one bounce buffer, 200 MiB each,
600 MB total:

```
ps3dd 200 MiB in  4.44 s (47.2 MB/s)
ps3da 200 MiB in  7.46 s (28.1 MB/s)
ps3db 200 MiB in 10.27 s (20.4 MB/s)

dmesg | grep -i deferring     (no output)
```

No deferrals and no errors. This is the case the shared tag set exists for:
three independent request queues, each with work pending, feeding one device
that accepts one command at a time. Every request was admitted through the
single tag, so `ps3disk_queue_rq()` never saw `priv->req` already set and the
`BLK_STS_DEV_RESOURCE` backstop never fired.

The throughput spread is the tag doing its job rather than a fault: the three
readers share one serialised device, so they divide its bandwidth instead of
multiplying it. Aggregate is roughly 95 MB/s across the three, which is about
what a single reader gets.

Two log lines above the driver's own output come from `ps3stor_lib.c` and are
now stale:

```
4 accessible regions found. Only the first one will be used
First accessible region has index 0 start 0 size 1875385008
```

`ps3disk` no longer reads `dev->region_idx`, so neither line describes what it
does. They are left alone deliberately — silencing them would mean patching
`ps3stor_lib.c`, which is the file this design goes out of its way not to
touch, and they remain accurate for `ps3flash` and `ps3rom`, which do still use
that field. Ignore them; the `OtherOS region is region 3` line below is the one
that matters.

### Mounting the other regions

`ps3dc`, the GameOS FAT32 cache region, mounts read-only from Debian and is a
usable file transfer path between the two systems:

```
mount -o ro /dev/ps3dc /mnt/gameos-cache
```

Read-only by default is what makes this safe to do casually.

`ps3db` is exposed but not mountable, because `CONFIG_UFS_FS` is off. That is
deliberate rather than an oversight: Linux UFS support is read-only and patchy,
GameOS uses its own variant, and there is nothing on that region worth reading
from Linux. The block device is still there for imaging if you want a backup.

## Module parameters

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `ps3disk.regions` | bitmask | `0` | Regions to expose. `0` means every accessible region. |
| `ps3disk.writable` | bitmask | `0` | Regions to expose read-write, in addition to the OtherOS region. Masked with the exposed set. |
| `ps3disk.otheros_rw` | bool | `Y` | Whether the detected OtherOS region is writable. |

Bit `n` is region `n`. All three are `0444`: read-only at runtime, set on the
kernel command line or in `/etc/modprobe.d`. They apply to every `ps3disk`
device, of which there is one.

```
ps3disk.regions=8                  # only the OtherOS region, still ps3dd
ps3disk.regions=0xc                # OtherOS and the cache region
ps3disk.otheros_rw=0               # everything read-only, for a rescue boot
```

Each unexposed region saves a `request_queue` and its per-CPU contexts — tens
of kilobytes, which on a 256 MB machine is worth having if you do not want
them.

## Considered and rejected

**T2's ABI change.** Adding `region_idx` to `ps3stor_read_write_sectors()`
changes an exported symbol, a header in `arch/powerpc/include/asm`, and two
unrelated drivers, to support a code path `ps3disk` does not use.

**Deriving the region from the minor number.** Covered above. Correct today,
fragile, and unnecessary.

**Keeping `dev->region_idx` for `ps3disk` and hiding the rest.** The `__fls`
hack. It discards information the hypervisor supplies, and its naming does not
match petitboot.

**Hiding region 0 by default.** Tempting, since it is the one that can destroy
everything. Rejected: read-only makes it harmless, and it is genuinely useful
for a full-drive backup. `regions=` excludes it for anyone who disagrees.

**`GENHD_FL_NO_PART` on non-OtherOS regions.** Would suppress partition
scanning on regions Linux has no table format for. Rejected as unnecessary —
the PS3's partition layout is not one Linux recognises, so the scan finds
nothing, and the cache region is a bare FAT32 filesystem that must stay
mountable.

Worth noting on the same subject: the OtherOS region's ext4 superblock is also
physically inside region 0, but Linux will not find it there, because it only
probes the start of a device and a partition table it cannot parse. There is
no duplicate-UUID confusion between `ps3da` and `ps3dd`.

**A custom udev rule as part of the patch.** Not needed, and worth separating
from the rule this repository does ship, because they answer different
questions.

The patch needs no udev support. Each region is an ordinary gendisk with its
own uevent; `systemd-udevd` and `initramfs-tools` see them the way they see any
other disk, partitions are scanned normally, and read-only status is exported
through the usual `ro` sysfs attribute. Nothing here is special-cased.

What *is* needed, on any PS3 running a modern systemd and regardless of this
patch, is `scripts/61-ps3-persistent-storage.rules`. systemd's
`60-persistent-storage.rules` matches `sd*`, `sr*`, `vd*`, `mmcblk*`, `cciss*`
and `pmem*`; `ps3d*` matches none of them, so the `blkid` builtin never runs and
`/dev/disk` is never created at all. That is an upstream gap in systemd, not
something the driver can or should fix.

## Porting forward

Written against Linux 6.4 (Geoff Levand's `ps3-linux`, close enough to
`v6.4` that the patch was generated against the pristine tag). Two block-layer
changes after 6.4 affect this file. Both are in `ps3disk_add_region()`, which
is where the queue setup was deliberately collected.

**6.9** — `blk_mq_alloc_disk()` takes a `struct queue_limits *`, and the
`blk_queue_*` setters are replaced by fields in it. Upstream converted
`ps3disk` in the same release. In `ps3disk_add_region()`, replace the
allocation and the six setters with:

```c
struct queue_limits lim = {
	.logical_block_size	= dev->blk_size,
	.max_hw_sectors		= BOUNCE_SIZE >> 9,
	.max_segments		= -1,
	.max_segment_size	= BOUNCE_SIZE,
	.dma_alignment		= dev->blk_size - 1,
	.features		= BLK_FEAT_WRITE_CACHE | BLK_FEAT_ROTATIONAL,
};

gendisk = blk_mq_alloc_disk(&priv->tag_set, &lim, rp);
```

**6.14** — `BLK_MQ_F_SHOULD_MERGE` was removed; pass `0` as the flags argument
to `blk_mq_alloc_sq_tag_set()`. Upstream `ps3disk` at v6.17 already does.

Nothing else in the patch depends on block-layer API that has moved.
`set_disk_ro()`, `device_add_disk()`, `del_gendisk()`, `put_disk()`,
`bitmap_find_next_zero_area()` and the tag-set sharing behaviour are all
unchanged as of v6.17.

One thing to re-check rather than assume when moving up: patch 0001. Upstream
`drivers/block/ps3disk.c` at v6.17 still copies every bio vector to offset
zero — the fix was posted in November 2025 and is not in v6.17. Verify whether
the tree you move to contains `offset += bvec.bv_len` before dropping 0001.

## What was and was not verified

The patch was generated with `diff -u` against the pristine `v6.4` tag from
`git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`, with patch 0001
applied first. Both patches apply to that tarball with no fuzz and produce
byte-identical output to the intended source.

Verified here:

- **Compiles clean.** `linux-6.4` + both patches, `ARCH=powerpc
  CROSS_COMPILE=powerpc64-linux-gnu-`, `ps3_defconfig` (`CONFIG_PPC64=y`,
  `CONFIG_CPU_BIG_ENDIAN=y`, `CONFIG_PS3_DISK=y`), gcc 11.2. Building
  `drivers/block/ps3disk.o` at `W=1` produces no warnings, and the full
  `vmlinux` links — `ELF 64-bit MSB executable, 64-bit PowerPC, Power ELF V1
  ABI`, with `ps3disk_probe`, `ps3disk_queue_rq`, `ps3disk_interrupt` and
  `ps3disk_remove` present in `System.map`.
- **Module parameters register correctly**, checked in `.modinfo`:
  `regions:ulong`, `writable:ulong`, `otheros_rw:bool`.
- **`checkpatch.pl --strict`**: 0 errors, 0 warnings, 3 checks — see below.
- **The blk-mq claims** above were checked against the 6.4 source rather than
  recalled: `hctx->tags = set->tags[hctx_idx]` in `blk_mq_init_hctx()` and
  `blk_mq_map_swqueue()`; `__blk_mq_alloc_disk()` passing `queuedata` through
  to the queue; `__blk_mq_requeue_request()` resetting a started request;
  `device_add_disk()` scanning partitions with `FMODE_READ`, so read-only
  disks still get partition nodes.

Verified on the console — see [Verified on hardware](#verified-on-hardware) for
the output. Booted first time on a CECH-2503B: region 3 detected as the OtherOS
region, the other three read-only, names matching petitboot, root mounted by
label, and the busy backstop never firing.

Still not verified, and worth stating:

- **Layouts other than this one.** Everything here is confirmed on a single
  console with a standard Evilnat OtherOS++ layout of four regions. The failure
  modes in [Is "highest-numbered" sound?](#is-highest-numbered-sound) are
  reasoned about, not observed. A NAND console, an original Sony OtherOS
  machine, or a system with two custom regions may behave differently.
- **Multiple hypervisor storage devices.** The letter-span allocator handles a
  second `ps3disk` device correctly by construction, but there is only one on
  this hardware, so that path has never executed.
- **Error and teardown paths.** `ps3disk_remove()`, the partial-failure unwind
  in probe, and the `BLK_STS_DEV_RESOURCE` backstop have not run, because
  nothing has failed. They are reviewed, not exercised.
- **Sustained throughput or long-term data integrity.** Confirmed working, not
  benchmarked or soak-tested.

## checkpatch

`checkpatch.pl --strict --patch` reports:

```
total: 0 errors, 0 warnings, 3 checks, 518 lines checked
```

The three `CHECK`s are all `spaces preferred around that ...`:

```c
blk_queue_dma_alignment(queue, dev->blk_size-1);
snprintf(..., PS3DISK_NAME, rp->devidx+'a');
set_capacity(gendisk, region->size*priv->blocking_factor);
```

All three are upstream lines moved from `ps3disk_probe()` into
`ps3disk_add_region()` with their spacing unchanged. checkpatch flags them
because they appear as added lines. They are kept as they are so the moved
code stays textually identical to what it replaced, which keeps future rebases
against upstream clean; reformatting them would be an unrelated change in a
patch that is already large.

## Credits

- **T2 SDE**, `architecture/powerpc64/package/linux/0010-ps3stor-multiple-regions.patch`,
  for establishing that the right answer is one block device per accessible
  region rather than a better choice of single region.
- **René Rebe** for the bounce buffer offset fix carried as patch 0001, and
  Christoph Hellwig for reviewing it.

Both drivers are GPL-2.0, so borrowing the approach outright is fine. The
differences here are per-region private data instead of minor arithmetic, a
shared tag set instead of implicit serialisation, read-only defaults, and
staying inside one file.
