# Porting to a 7.x kernel: what it would take

Scope: a report, not a change. Nothing outside this file was touched.

Everything below was determined by reading source and archives on 2026-08-18.
Nothing here was tested on hardware, and no kernel was built. That distinction
matters throughout: it is why the "could not determine" section exists and why
the estimate has a tail.

Sections 1–3 separate **Findings** (with sources) from **Inference** (what I
conclude from them). Where I could not determine something, it is in
[What I could not determine](#what-i-could-not-determine) rather than guessed at.

---

## 0. The facts, established first

### 0.1 What mainline actually is

**Finding.** 7.x exists. The numbering ran 6.18 → 6.19 → 7.0.

| Release | Moniker | Date |
|---|---|---|
| 7.2 | mainline | 2026-08-16 |
| 7.1.8 | stable | 2026-08-09 |
| 6.18.44 | longterm | 2026-08-09 |
| 6.12.103 | longterm | 2026-08-09 |
| 6.6.151 | longterm | 2026-08-09 |
| 6.1.182 | longterm | 2026-08-07 |

Source: `https://www.kernel.org/releases.json`, fetched 2026-08-18. The existence
of `v6.19`, `v7.0` and `v7.1` was confirmed independently by successfully
fetching `drivers/block/ps3disk.c` at each of those tags from
`git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`.

So the target is real, and "7.x" is currently 7.0, 7.1 or 7.2. The newest LTS is
6.18, supported to December 2028.

### 0.2 Geoff Levand's `ps3-linux` tree

**Finding.** The tree has *not* stopped at 6.4, but it has stopped.

Queried with `git ls-remote` against
`https://git.kernel.org/pub/scm/linux/kernel/git/geoff/ps3-linux.git` — this is
authoritative, unlike the web UI summaries, which disagreed with each other:

- **Tags** stop at `v6.4-rc7`. There is no tag past that.
- **`master`** is `98ec4e7cee0f26a1af070ffc697d82c0f2714848`,
  "Merge branch 'ps3-queue-v6.4'".
- **Branches**, however, continue: `ps3-queue-v6.5` through
  **`ps3-queue-v6.13`**.

`ps3-queue-v6.13` was last committed **2024-12-02** and is based on **6.13-rc1**,
not final 6.13. Source: googlesource JSON log for that ref.

Its delta over mainline is **16 commits**:

- `ps3_defconfig` refreshes, plus `local:` NFS and petitboot defconfigs (5–11)
- `ps3-debugging: Setup DABR register`, `Enable CONFIG_IKCONFIG_PROC` (12–13)
- `hvc_console: Allow backends to set I/O buffer size` (14)
- gelic work: `Use napi routines for RX SKB`, `gelic skb cleanup`,
  `Use page_frag_free` (1, 2, 15)

**Inference.** As of today the tree is ~20 months stale and eight releases behind
mainline (6.14–6.19, 7.0–7.2). But this matters far less than it looks, because
the queue is thin and mostly not needed here:

- The `local:` defconfigs are for NFS root and petitboot, not this project.
- The debugging commits are aids, not requirements.
- The **gelic work appears to have gone upstream**: mainline
  `drivers/net/ethernet/toshiba` gained "net: ps3_gelic_net: handle skb
  allocation failures" (Florian Fuchs, 2025-11-18) and "Use napi_alloc_skb() and
  napi_gro_receive()" (Florian Fuchs, 2025-12-01), which correspond to what
  Levand was carrying.

So the PS3 platform code does **not** need forward-porting. It is in mainline and
is being maintained there — see §2.3. What Levand's tree adds on top is small and
largely superseded. This is the single most load-bearing conclusion in this
report, because it converts the job from "forward-port a platform" to "rebase one
driver patch".

Note for the installer: `make-debian-installer.sh:715` does
`git clone --depth 1 …ps3-linux.git` with **no branch**, so it takes `master`,
i.e. 6.4. Any retarget changes that line.

### 0.3 René Rebe's bounce-buffer fix

**Finding.** It is upstream, and it is in every target you would plausibly pick.

The commit is **"ps3disk: use memcpy_{from,to}_bvec index", René Rebe,
2025-11-14** (from the cgit history of `drivers/block/ps3disk.c`, `+4` lines).

Bisected by fetching the file at each tag and grepping for `offset += bvec.bv_len`:

| Tag | Fix present |
|---|---|
| v6.4 | no |
| v6.12 | no |
| v6.18 | **no** |
| v6.19 | **yes** |
| v7.0, v7.1, v7.2 | yes |

So it landed in **6.19**. It was also **backported to stable**, confirmed by
fetching from `stable/linux.git`:

| Stable tag | Fix present |
|---|---|
| 6.18.44 | yes |
| 6.12.103 | yes |
| 6.6.151 | yes |

**Inference.** `patches/0001` is unnecessary on 7.x, and equally unnecessary on
any current LTS *point release*. It is still needed only if you build a bare
`.0` tag between 6.4 and 6.18. The patch set halves, as you expected — and it
halves on more targets than you expected.

This updates `docs/region-handling.md`, which correctly says the fix was absent
at v6.17 and says to re-check. It is now present.

The upstream version also adds a `dev_dbg()` alongside the offset increment, so
it is not a byte-identical match to `patches/0001`, but the corrective line is
the same.

---

## 1. Does patch 0002 still apply, and what breaks

`patches/0002` touches only `drivers/block/ps3disk.c`. I diffed that file between
v6.4 and v7.2 and read the relevant block-layer headers at both.

### 1.1 The two known changes — both confirmed

**6.9, `blk_mq_alloc_disk()` takes `struct queue_limits *`.** Confirmed:

```
v6.4   blk_mq_alloc_disk(&priv->tag_set, dev)
v6.12  blk_mq_alloc_disk(&priv->tag_set, &lim, dev)
v6.18  blk_mq_alloc_disk(&priv->tag_set, &lim, dev)
v7.2   blk_mq_alloc_disk(&priv->tag_set, &lim, dev)
```

**Your assumption that this is a single localised edit still holds.** Patch 0002
deliberately collects all six `blk_queue_*` setters into `ps3disk_add_region()`,
and all six are exactly the ones that became `queue_limits` fields. The
replacement is one `struct queue_limits lim = { … }` plus the changed
`blk_mq_alloc_disk()` call, both inside `ps3disk_add_region()`. Nothing else in
the patch touches queue setup. The snippet already written in
`docs/region-handling.md` under "Porting forward" is correct and compiles against
what v7.2 actually does — I compared it to upstream's own block and they match
field for field.

**6.14, `BLK_MQ_F_SHOULD_MERGE` removed.** Confirmed. The flag is present in
`include/linux/blk-mq.h` at v6.4 and v6.12, absent at v6.18 and v7.2. The
upstream removal is "block: remove BLK_MQ_F_SHOULD_MERGE", Christoph Hellwig,
2024-12-23. `blk_mq_alloc_sq_tag_set()` still takes a `set_flags` argument, so
the edit is passing `0`.

### 1.2 The load-bearing question: does the shared depth-one tag set still hold

**It does, unchanged. The serialisation argument in `docs/region-handling.md`
does not need revisiting.** This is the finding I was most careful about, because
you flagged it as the one that would invalidate the design rather than the code.

Three things had to hold, and all three do:

**One tag set with `nr_hw_queues == 1` still means one bitmap shared by every
queue.** `blk_mq_alloc_sq_tag_set()` is **byte-identical** between v6.4 and v7.2
(`diff` of the function body is empty) and still sets `nr_hw_queues = 1`. In
`block/blk-mq.c` at v7.2, `hctx->tags = set->tags[hctx_idx];` (line 3995). With
one hardware queue, every region queue's `hctx` resolves to `set->tags[0]` — the
same `blk_mq_tags`, the same `sbitmap`. That is the mechanism the patch relies
on and it is intact.

**The transition to shared accounting still happens.** `blk_mq_add_queue_tag_set()`
still sets `BLK_MQ_F_TAG_QUEUE_SHARED` when the second queue joins the set. The
only difference from v6.4 is `list_add_tail()` → `list_add_tail_rcu()`, which is
internal bookkeeping with no driver-visible effect.

**The fairness limiter still cannot starve a depth-one set.** This was the real
risk: with shared tags, blk-mq divides the depth among active queues, and
`1 / 4 == 0` would deadlock. It does not, because `hctx_may_queue()` in
`block/blk-mq.h` short-circuits first:

```c
/*
 * Don't try dividing an ant
 */
if (bt->sb.depth == 1)
    return true;
```

The only change to that function between v6.4 and v7.2 is
`atomic_read(&hctx->tags->active_queues)` → `READ_ONCE(hctx->tags->active_queues)`.
The depth-1 early return is present in both.

So the single tag remains the device-wide permit to use the bounce buffer, held
from `blk_mq_start_request()` to `blk_mq_end_request()`, exactly as
`docs/region-handling.md` describes. No revision needed to that document's
reasoning — only to its version numbers.

### 1.3 The specific APIs you asked about — all unchanged

| API | v6.4 → v7.2 |
|---|---|
| `blk_mq_start_request(struct request *rq)` | identical signature |
| `BLK_STS_DEV_RESOURCE` | still `((__force blk_status_t)13)`; doc comment describing its semantics is identical |
| `memcpy_from_bvec` / `memcpy_to_bvec` | bodies identical; only kernel-doc `@to:`/`@from:` lines added |
| `blk_mq_run_hw_queues(q, bool async)` | identical signature |
| `set_disk_ro`, `device_add_disk`, `del_gendisk`, `put_disk` | all present in `blkdev.h` |
| `bitmap_find_next_zero_area`, `bitmap_set`, `bitmap_clear` | present |
| `struct_size` | present |
| `struct ps3_storage_device` (`asm/ps3stor.h`) | **file byte-identical** |

That last row matters: `accessible_regions`, `num_regions`, `regions[]` and
`region_idx` — everything patch 0002 reads from the hypervisor device — are
untouched between 6.4 and 7.2.

### 1.4 Additional changes found, that the brief did not list

**(a) A real upstream bug you must not re-introduce.**
"ps3disk: Do not use `dev->bounce_size` before it is set", Geert Uytterhoeven,
2025-01-03. When upstream converted to `queue_limits`, it put the initialiser at
the top of `ps3disk_probe()`:

```
v6.12:  line 385   struct queue_limits lim = { .max_hw_sectors = dev->bounce_size >> 9, … };
        line 424   dev->bounce_size = BOUNCE_SIZE;
```

The initialiser is evaluated at function entry, so it read **zero**. Fixed by
using the `BOUNCE_SIZE` constant directly; v6.18 and v7.2 do that, and it is
backported (6.12.103 has it, 6.12.0 does not).

This is directly relevant to the port. In patch 0002 the queue setup lives in
`ps3disk_add_region()`, which is called *after* `dev->bounce_size` is assigned,
so `dev->bounce_size` would in fact be valid there. But if the port instead
hoists a `lim` to the top of `ps3disk_probe()` — the obvious thing to do when
copying upstream's shape — it walks straight into the same zero. **Build `lim`
inside `ps3disk_add_region()` and use `BOUNCE_SIZE`.**

**(b) The `BLK_MQ_F_*` flag set changed more than one entry.**
Removed: `BLK_MQ_F_SHOULD_MERGE`, `BLK_MQ_F_NO_SCHED`,
`BLK_MQ_F_ALLOC_POLICY_BITS`, `BLK_MQ_F_ALLOC_POLICY_START_BIT`.
Added: `BLK_MQ_F_TAG_RR`, `BLK_MQ_F_MAX`.
Patch 0002 uses none of the removed ones except `SHOULD_MERGE`, so no further
edit — but a rebase that tries to be clever about tag allocation policy would
find the old symbols gone.

**(c) Allocation idiom changed; the old one still works.**
v7.2 `ps3disk_probe()` now uses `kzalloc_obj(*priv)`. Patch 0002 uses
`kzalloc(struct_size(priv, disk, dev->num_regions), GFP_KERNEL)`. Plain
`kzalloc(size, flags)` still exists at v7.2 (`include/linux/slab.h:1320`), so
this compiles unchanged. There is now a `kzalloc_flex(P, FAM, COUNT, …)` macro
that is exactly this flexible-array case, and the treewide conversions
("treewide: Replace kmalloc with kmalloc_obj for non-scalar types", Kees Cook,
2026-02-21; Linus's `alloc_obj`/`alloc_flex` GFP-default follow-ups) mean
`checkpatch` or a reviewer may want the new form. **Cosmetic, not blocking.**

### 1.5 Verdict on section 1

Patch 0002 will not apply cleanly — the context around the queue setup and the
tag-set allocation has moved. But every change is mechanical and confined to the
two places the patch already isolated. The design does not change. Concretely,
the rebase is:

1. In `ps3disk_add_region()`: replace six `blk_queue_*` setters with a
   `struct queue_limits lim` using `BOUNCE_SIZE`, and pass `&lim` to
   `blk_mq_alloc_disk()`.
2. In `ps3disk_probe()`: pass `0` instead of `BLK_MQ_F_SHOULD_MERGE`.
3. Optionally, switch `kzalloc(struct_size(...))` to `kzalloc_flex(...)`.
4. Re-diff against the chosen tag and re-run `checkpatch`.

Everything else in the 320-line patch — region private data, the OtherOS
detection, the read-only policy, the naming scheme, the lifecycle, the busy
backstop — rebases as context.

---

## 2. Does `ps3_defconfig` still work

### 2.1 It still exists, and it barely moved

**Finding.** `arch/powerpc/configs/ps3_defconfig` is present at v7.2. The diff
from v6.4 is five hunks, all of them upstream-wide renames rather than PS3
changes:

- `CONFIG_EMBEDDED=y` → `CONFIG_EXPERT=y` (treewide, 2023-08-21)
- `CONFIG_SLAB=y` dropped (SLAB removed upstream)
- `CONFIG_AUTOFS4_FS=m` → `CONFIG_AUTOFS_FS=m` (treewide, 2023-07-29)
- `CONFIG_CRYPTO_PCBC`, `CRYPTO_MICHAEL_MIC`, `CRC_CCITT`, `CRC_T10DIF` dropped
  (those symbols lost their prompts or were removed upstream)

No PS3 driver line changed.

Worth noting: `kernel-config.sh` already sets `AUTOFS_FS`, which is the correct
modern name. That one is already right.

### 2.2 The drivers are all present

**Finding.** Every file exists at v7.2 (checked by HTTP status against the
torvalds tree):

`drivers/block/ps3disk.c`, `drivers/block/ps3vram.c`,
`drivers/video/fbdev/ps3fb.c`, `drivers/scsi/ps3rom.c`,
`drivers/char/ps3flash.c`, `sound/ppc/snd_ps3.c`,
`drivers/net/ethernet/toshiba/ps3_gelic_net.c`,
`arch/powerpc/platforms/cell/spufs/`, `arch/powerpc/platforms/ps3/`.

And `ps3_defconfig` at v7.2 still selects them:

```
CONFIG_PPC_PS3=y      CONFIG_PS3_DISK=y     CONFIG_PS3_ROM=y
CONFIG_PS3_FLASH=y    CONFIG_PS3_VRAM=m     CONFIG_PS3_LPM=m
CONFIG_GELIC_NET=y    CONFIG_GELIC_WIRELESS=y
CONFIG_FB_PS3=y       CONFIG_RTC_DRV_PS3=y  CONFIG_CELL_CPU=y
```

### 2.3 `CONFIG_SPU_FS` still exists — but note it is not in the defconfig

**Finding.** At v7.2, in `arch/powerpc/platforms/cell/Kconfig`:

```
config SPU_FS
	tristate "SPU file system"
	default m
	depends on PPC_CELL
	depends on COREDUMP
	select SPU_BASE
```

The symbol is alive and its dependencies are satisfiable on PS3 (`PPC_PS3`
selects `PPC_CELL`).

**But `CONFIG_SPU_FS` appears in `ps3_defconfig` at neither v6.4 nor v7.2.** It
is `default m` and `PPC_CELL` is selected, so `olddefconfig` should give you
`SPU_FS=m` — but that is the Kconfig default doing the work, not the defconfig
asking for it, and `kernel-config.sh` does not list it either.

**Inference.** Since the SPE work is the point of the project, `SPU_FS` (and
`COREDUMP`, which it now depends on) belongs in `kernel-config.sh`'s `BUILTIN`
list or an equivalent explicit list, on **both** 6.4 and 7.x. This is a
pre-existing gap the port surfaces rather than creates. It is exactly the class
of problem the script's own comment describes — "three of these were silently
modules" — and it is cheap to close.

### 2.4 The big scare in `platforms/cell`, and why it does not bite

**Finding.** A large amount of `arch/powerpc/platforms/cell/` was **removed**
between 6.12 and 6.18. Gone from `cell/Kconfig`: `PPC_CELL_COMMON`,
`PPC_CELL_NATIVE`, `PPC_IBM_CELL_BLADE`, `AXON_MSI`, `CBE_RAS`, `CBE_THERM`,
`PPC_IBM_CELL_RESETBUTTON`, `PPC_IBM_CELL_POWERBUTTON`, `PPC_PMI`,
`CBE_CPUFREQ_SPU_GOVERNOR`. The `spider_net` driver was deleted outright
("net: spider_net: Remove powerpc Cell driver", Michael Ellerman, 2025-02-26,
−3216 lines), with a companion "net: toshiba: Remove reference to
PPC_IBM_CELL_BLADE".

**This is the IBM Cell blade support being removed, not Cell itself.** What
survives:

- `config PPC_CELL` — survives.
- `config SPU_FS` — survives, still `depends on PPC_CELL`.
- `config SPU_BASE` — survives.
- `config CELL_CPU` in `Kconfig.cputype` — survives, unchanged from v6.4.

And critically, the `PPC_PS3` Kconfig block is **byte-identical** between v6.4
and v7.2:

```
config PPC_PS3
	bool "Sony PS3"
	depends on PPC64 && PPC_BOOK3S && CPU_BIG_ENDIAN
	select PPC_CELL
	…
```

PS3 selects `PPC_CELL`, which was retained. It never selected
`PPC_CELL_COMMON`/`PPC_CELL_NATIVE`, which were the blade-only paths.

**Inference.** PS3 is unaffected by the largest-looking removal in this range.
This is worth knowing precisely, because a superficial look at the diff — "they
deleted half of platforms/cell" — would reasonably read as project-ending and is
not.

### 2.5 Nothing in `platforms/ps3` is deprecated, moved or removed

**Finding.** Diff of `arch/powerpc/platforms/ps3/Kconfig`, v6.4 → v7.2, is two
hunks:

- `PS3_PS3AV` gained `select VIDEO` (from "drivers/ps3: select VIDEO to provide
  cmdline functions", Randy Dunlap, 2024-02-09).
- `PS3GELIC_UDBG` was **removed** — the "udbg output via UDP broadcasts on
  Ethernet" early-debug facility.

No `BROKEN` markers, no deprecation language, nothing moved.

**Inference.** The `PS3GELIC_UDBG` removal is the one to be aware of, and it
cuts against you specifically: on hardware whose only console is a television,
an early-boot debug channel that sends over the network was one of the few
things that made a failed boot diagnosable. It is gone. If the 7.x bring-up goes
badly, you have fewer tools than the 6.4 bring-up had. That is an argument for
choosing a target where fewer things can go wrong, not for choosing the newest.

### 2.6 Big-endian ppc64 and ELF ABI v1: supported, no wind-down signal

**Finding.** At v7.2, in `arch/powerpc/platforms/Kconfig.cputype`:

```
choice
	prompt "Endianness selection"
	default CPU_BIG_ENDIAN
…
config PPC64_ELF_ABI_V1
	def_bool PPC64 && (CPU_BIG_ENDIAN && !PPC64_BIG_ENDIAN_ELF_ABI_V2)
```

Big-endian is still the **default** of the endianness choice. The entire
endianness/ABI region of that file is **byte-identical** between v6.4 and v7.2.
Grepping `Kconfig.cputype` at v7.2 for `deprecat|obsolete|BROKEN|will be
removed|no longer` returns nothing.

**Inference.** No wind-down signal for BE ppc64 or ABI v1 in the kernel config.
This does not tell you about toolchain or distro intentions, only the kernel's.

### 2.7 The one genuine PS3 breakage in this range — already found and fixed

This is the answer to "search the archives; if someone has already hit and fixed
something, that is worth more than us discovering it on hardware." Someone did.

**Finding.** `PPC64_BIG_ENDIAN_ELF_ABI_V2` changed meaning after 6.4:

| Tag | Definition |
|---|---|
| v6.4 | `bool "… (EXPERIMENTAL)"` — opt-in, default **n** |
| v6.7 onward, incl. v7.2 | `def_bool y`, prompt only `if LD_IS_BFD && EXPERT` |

So from 6.5-rc1 ("powerpc/64: Make ELFv2 the default for big-endian builds",
commit `8c5fa3b5c4df`), big-endian ppc64 kernels build with the **ELFv2** calling
convention by default. That was incompatible with the PS3's LV1 hypervisor call
assembly and produced a NULL pointer dereference at boot. It carries
CVE-2023-52665.

The repair history, from the cgit logs of `arch/powerpc/configs/ps3_defconfig`
and `arch/powerpc/platforms/ps3`:

- **2023-12-29** Geoff Levand: "powerpc/ps3_defconfig: Disable
  PPC64_BIG_ENDIAN_ELF_ABI_V2" — a defconfig workaround.
- **2024-02-21** Nicholas Piggin, three commits:
  "powerpc/ps3: Fix lv1 hcall assembly for ELFv2 calling convention";
  "powerpc/ps3: lv1 hcall code use symbolic constant for LR save offset";
  "powerpc/ps3: Make real stack frames for LV1 hcalls".
- **2024-02-21** Geoff Levand: **Revert** "powerpc/ps3_defconfig: Disable
  PPC64_BIG_ENDIAN_ELF_ABI_V2" — the workaround withdrawn the same day the real
  fix landed.

I verified the defconfig side directly: the
`# CONFIG_PPC64_BIG_ENDIAN_ELF_ABI_V2 is not set` line appears in `ps3_defconfig`
at **v6.8 only**, and is absent at v6.5, v6.6, v6.7, v6.9, v6.10, v6.11, v6.12,
v6.18 and v7.2.

**Inference — and this is the sharpest planning consequence in the report:**
kernels **6.5 through 6.8** are a poisoned window for PS3. They default to ELFv2
without the fixed hcall assembly (except 6.8, which has only the defconfig
workaround). Everything **6.9 and later — including 6.12, 6.18, 7.0, 7.1 and
7.2 — is fixed in code** and needs no defconfig override. The absence of that
line at v7.2 is correct, not a regression.

Any migration plan that stops at an intermediate release in 6.5–6.8 would hit a
boot failure that has nothing to do with your patches, and would cost console
cycles to diagnose.

### 2.8 The platform is still actively maintained

**Finding.** Recent commits touching `arch/powerpc/platforms/ps3`:

- 2026-07-28 "powerpc/ps3: Fix map failure path in `dma_ioc0_map_pages()`" (Thorsten Blum)
- 2026-07-28 "powerpc/ps3: Remove unused struct table in `setup_areas()`" (Thorsten Blum)
- 2026-06-02 "powerpc: use `sysfs_emit{_at}` in sysfs show functions"
- 2026-05-06 "powerpc/ps3: Drop redundant result assignment"
- 2026-04-01 "powerpc/ps3: spu.c: fix enum and Return kernel-doc warnings"
- 2025-10-29 "powerpc: Convert to physical address DMA mapping" (−14/+19 in ps3)

And in the drivers: gelic NAPI/skb work through 2025-12; `snd_ps3` `guard()`
conversion 2025-09; `ps3fb` touched 2026-06 by an fbdev-wide refactor;
`drivers/ps3/ps3stor_lib.c` touched 2025-09.

**Inference.** PS3 is not abandoned upstream — it is getting janitorial and
API-migration attention as recently as three weeks ago. That is good for
"will it still compile" and says **nothing** about "will it still boot", because
none of these changes were tested on a console. Which is the whole risk.

Note for `kernel-patch.sh`: it asserts `drivers/ps3/ps3stor_lib.c` does not
contain the old `__fls(dev->accessible_regions)` hack. That file has changed
upstream (2025-09-06, `str_write_read()`), but the assertion is a grep for the
hack, so it still behaves correctly.

---

## 3. Does the rest of the toolchain still work

### 3.1 Debian ports ppc64 — alive and building

**Finding.** `http://deb.debian.org/debian-ports/dists/sid/Release`:

```
Architectures: all alpha hppa hurd-amd64 hurd-i386 m68k powerpc ppc64 sh4 sparc64 x32
Date: Tue, 18 Aug 2026 18:22:38 +0000
Valid-Until: Tue, 25 Aug 2026 18:22:38 +0000
```

`ppc64` is listed, and the index was regenerated **today**. I downloaded
`main/binary-ppc64/Packages.xz` (18 MB) and counted **92,806 binary packages**.

Versions of what the scripts need:

| Package | Version in sid/ppc64 |
|---|---|
| initramfs-tools | 0.151 |
| systemd, systemd-sysv, udev | 261.2-1 |
| busybox | 1:1.38.0-3 |
| klibc-utils | 2.0.14-1+b2 |
| libc6 | 2.43-3 |
| openssh-server | 1:10.4p1-4 |
| e2fsprogs | 1.47.4-1+b1 |

**Inference.** The port is not dead and not stalled — 92k packages at current
versions is an actively autobuilt architecture. `build-rootfs.sh`'s `SUITE=sid`,
`ARCH=ppc64`, `MIRROR=…/debian-ports` and the `unreleased` suite line all remain
valid. This does not end the project.

### 3.2 `initramfs-tools` — the assumed interface is intact

**Finding.** Read the Debian changelog for 0.143 → 0.151. The documented
invocation `mkinitramfs -o /boot/initrd.img <kernel release>`, used in README
step 4 and by `make-debian-installer.sh`, is unchanged. Changes in this range are
concentrated in `unmkinitramfs` (rewritten in C, then moved to a new
`initramfs-tools-bin` package, then taught to prefer `3cpio`), `update-initramfs`
hook loading from `/usr/share`, and `hook-functions` driver-list additions.

Two entries bear on the chroot workflow, and both are favourable:

- "hook-functions: avoid aborting in chroots"
- "Support 3cpio and prefer 3cpio over cpio" — `mkinitramfs` uses `3cpio` when
  present and `cpio` otherwise, so neither is a new hard requirement.

**Inference.** `mkinitramfs` in a chroot still behaves as documented. I found no
change that invalidates README step 4 or `build-rootfs.sh`'s decision to install
`initramfs-tools` without running it. The `CONFIG_RD_ZSTD` warning behaviour that
step 4 documents is unaffected by anything in this range.

### 3.3 systemd — no version blocker, some symbol gaps

**Finding.** From systemd's `README` (requirements live in the extensionless
`README`, not `README.md`, as of current main):

> Kernel versions below 5.10 ("minimum baseline") are not supported at all

7.x clears this with enormous margin. Individual feature floors named are ≥3.15,
≥5.11 (`epoll_pwait2()`), ≥5.15 (`MPOL_PREFERRED_MANY`) — all satisfied.

Comparing systemd's list against `kernel-config.sh`'s `BUILTIN` list, these
appear in systemd's requirements and **not** in the script:

| Symbol | Kconfig default | Consequence if absent |
|---|---|---|
| `CFS_BANDWIDTH` | **n** | `CPUQuota=` unavailable |
| `PSI` | **n** | `systemd-oomd` unavailable |
| `BPF_JIT` | varies | `IPAddressAllow=`/`IPAddressDeny=` degraded |
| `NET_SCHED`, `NET_SCH_FQ_CODEL` | n | "strongly recommended" |
| `IPV6` | — | "strongly recommended" |
| `RT_GROUP_SCHED` | — | recommended **off** |

And these are listed by systemd but are **not** gaps, which is worth recording so
nobody adds them needlessly:

- `SIGNALFD`, `TIMERFD`, `EPOLL` — all `default y` in `init/Kconfig` at v7.2,
  with prompts only visible under `EXPERT`. `olddefconfig` keeps them `y`.
  (`ps3_defconfig` does set `CONFIG_EXPERT=y`, which makes them *visible*; it
  does not make them default off.)
- `UNIX` — `CONFIG_UNIX=y` is explicit in `ps3_defconfig`.
- `SYSFS`, `PROC_FS`, `INOTIFY_USER` — default y.
- `KCMP` — systemd's README says "not needed after 6.10", so on a 7.x target this
  requirement disappears entirely. It is a 6.4-era concern only.

**Inference.** systemd 261 introduces **no new mandatory kernel symbol** that
would stop PID 1 booting on a 7.x PS3 kernel. The cgroup-v2, namespace, seccomp
and `FHANDLE` requirements — the ones that actually gate boot — are all already
covered by `kernel-config.sh`, which was evidently written against a careful
reading. The gaps above degrade optional features (`CPUQuota=`, `oomd`, IP
filtering), not startup.

I would add `CFS_BANDWIDTH` and `PSI` while touching the list anyway, since both
are one line and both are `default n`. `SPU_FS` and `COREDUMP` matter more —
see §2.3.

**Caveat.** These conclusions come from reading Kconfig defaults, not from
running `olddefconfig` on a real tree. The script exists precisely because that
reasoning is not reliable — its own comment records three symbols that were
silently modules. Treat §3.3 as a list to verify with the script's own verify
loop, which is the right tool and already written.

---

## 4. Recommended route

### 4.1 Should you step through an intermediate LTS?

**No. Go in one jump.** The argument for stepping through 6.12 — that PowerPC
fallout is more likely already fixed in an LTS — turns out not to apply here, for
three reasons that only became visible once the facts were established.

**The PS3-specific breakage in this range was fixed in 6.9, not in an LTS.**
The ELFv2 hcall problem (§2.7) is the only PS3 boot-breaking change between 6.4
and 7.2 that I found. Every candidate target ≥6.9 has the fix. Stopping at 6.12
gives you nothing that 6.18 or 7.1 does not already have.

**A 6.12 stop does not reduce the patch work — it splits it and adds a step.**
Compare what patch 0002 needs at each target:

| Target | `queue_limits` edit | `SHOULD_MERGE` edit | patch 0001 |
|---|---|---|---|
| 6.12.103 | **required** | not yet (flag still exists) | not needed |
| 6.18.44 | **required** | **required** | not needed |
| 7.1.8 / 7.2 | **required** | **required** | not needed |

6.12 makes you do the *harder* of the two edits (the `queue_limits` conversion)
and defers only the trivial one (passing `0`). You would then do the trivial edit
later anyway. The intermediate stop costs a full build-image-write-boot cycle and
buys a one-line deferral.

**Every candidate already has patch 0001.** So the "patch set halves" benefit is
not a reason to prefer one target over another — 6.12.103, 6.18.44 and 7.x all
have René Rebe's fix backported (§0.3).

**Argued the other way, honestly:** the case for an intermediate step would be
that it bisects unknown *runtime* breakage — if 7.x does not boot, a working 6.12
tells you the problem entered after 6.12. That is a real benefit and it is the
only one. But it costs a full hardware cycle up front to buy debugging
information you may never need, on a target you do not want to ship. If 7.x fails
to boot, you can build 6.12 *then*, as a bisection tool, having spent nothing in
the case where it works. **Defer the intermediate build; do not schedule it.**

### 4.2 Which target

**Recommendation: 6.18.x LTS (currently 6.18.44).**

The port work is **identical** to 7.x — same `queue_limits` edit, same
`SHOULD_MERGE` edit, same dropped 0001, same defconfig. I verified this: at
v6.18, `BLK_MQ_F_SHOULD_MERGE` is already gone, `queue_limits` is already
required, and 6.18.44 carries the bounce-buffer fix. There is no version of this
job where 6.18 is more work than 7.2.

What 6.18 buys over 7.1/7.2: support until **December 2028**, a point release
that has absorbed nine months of fixes, and no exposure to churn in a release
that is two days old at time of writing (7.2 shipped 2026-08-16).

**If you specifically want 7.x**, take **7.1.8** rather than 7.2 — same work,
same edits, but 7.1.8 is a stable point release rather than a mainline tag from
this week. Note that 7.x is the only place where 0001 is in the *base* tag rather
than a backport, which is tidy but not worth much.

**Where to get the tree.** Given §0.2, clone mainline
(`torvalds/linux.git`) at the chosen tag rather than Levand's `master`. Levand's
`ps3-queue-v6.13` is worth reading for the `hvc_console` I/O buffer size commit
if console behaviour disappoints, but it is not a base to build on — it is stale,
based on an -rc, and its gelic content is upstream.

### 4.3 Cost per step

| Step | Cost |
|---|---|
| 6.4 → 6.18.x (recommended) | one rebase, one build, one hardware cycle to first boot |
| 6.4 → 7.1.8 | identical work; younger base |
| 6.4 → 6.12 → 7.x | the above **plus** a full extra cycle, buying only bisection insurance |

---

## 5. Estimate

Hours are working hours for someone who already knows this codebase. The
dominant variable is not code — it is that every attempt is a kernel build, an
image build, a USB transfer, a console write, a reboot, and a television.

### 5.1 Near-certain mechanical work — 6 to 11 hours

| Task | Hours |
|---|---|
| Rebase 0002 onto the target; regenerate against the pristine tag; `checkpatch` | 3–6 |
| Drop 0001: `kernel-patch.sh` apply+marker, `detect_state` grep, README, `region-handling.md` | 1–2 |
| Retarget the clone (mainline tag instead of Levand `master`) | 0.5–1 |
| Refresh `kernel-config.sh` list (`SPU_FS`, `COREDUMP`, `CFS_BANDWIDTH`, `PSI`); run its verify loop | 1–2 |

Confidence here is high because the API deltas are enumerated in §1 from source,
not inferred.

### 5.2 Likely but unknown — 8 to 28 hours

| Task | Hours | Why unknown |
|---|---|---|
| First clean cross-build | 2–8 | I did not build. Eight releases of unrelated churn; PS3 gets little build coverage in BE ppc64 configs |
| `olddefconfig` fallout | 2–6 | The "silently became modules" class. Determinable in one build |
| Size budget: kernel + initrd into 256 MB alongside petitboot | 1–4 | README budgets ~19 MB vmlinux + ~15 MB initrd. Kernels have grown; may need config trimming |
| First boot and bring-up on hardware | 3–10 | 2–6 console cycles at ~40 min each, per `region-handling.md` |

### 5.3 Things that could sink it

Not ranked by likelihood — ranked by how badly they end the project.

**Nobody has booted a PS3 on ≥6.14 that I can find.** Upstream PS3 changes since
Levand stopped in December 2024 — including the DMA physical-address conversion
(2025-10-29), the irqdomain fwnode migration (2025-05), and the July 2026
`dma_ioc0_map_pages()` fix — are compile-tested, not hardware-tested. If one of
them is wrong on real LV1, you are the person who finds out, without
`PS3GELIC_UDBG` (§2.5) and reading a television. **Unbounded; realistically
0–20 hours.**

**A driver regressed in a refactor done for platforms people actually use.**
This is the risk you named and it is correctly named. The live candidates:
`ps3fb` was touched by an fbdev-wide `fb_set_var()` wrapper change (2026-06-09);
gelic was substantially reworked for NAPI/skb handling (2025-11 to 2025-12);
`snd_ps3` was converted to `guard()` locking (2025-09). Each is plausible and
each would cost **4–20 hours** to isolate on this hardware.

**Petitboot cannot kexec the result.** If the kernel plus initrd no longer fit
the budget alongside petitboot in 256 MB, that is a config-trimming exercise
with a slow feedback loop. **2–10 hours.**

**Low risk, for completeness:** the region logic itself. `asm/ps3stor.h` is
byte-identical, `ps3stor_probe_access()` behaviour is unchanged, and the tag
sharing holds (§1.2). The part of this project that is *yours* is the part least
likely to break.

### 5.4 Total, and what it depends on

**15–50 hours**, with a long tail. Median expectation around **20–25 hours** if
the first cross-build is close to clean and the console boots within a few
cycles.

The estimate depends on, in order of leverage:

1. **Whether the first cross-build succeeds.** Cheap to find out, no hardware
   needed, and it collapses most of §5.2. **Do this first.**
2. **How many console cycles first boot takes.** The difference between 2 and 8
   is the difference between 20 and 30 hours.
3. **Whether `ps3fb`, gelic or `snd_ps3` regressed.** Binary; each is hours.

Because reading source is so much cheaper than testing here, note that §5.1 and
most of §5.2 can be driven to near-certainty *before* the console is touched at
all. The first hardware write should happen once, with everything else already
verified.

---

## 6. How the installer would eventually offer the choice

Described, not built. Split into what would need **changing** versus **extending**.

### 6.1 `patches/` — extend

Per-version subdirectories: `patches/6.4/` keeping both patches, `patches/6.18/`
holding only the rebased 0002. `kernel-patch.sh` already takes the tree as an
argument and computes its patch directory from `$HERE`; it grows a version
argument and a loop over whatever is in that directory, instead of two hardcoded
`apply` calls. Its marker-based idempotence check generalises cleanly — each
patch file gets an associated marker.

**Extension. The script's structure already anticipates this.**

### 6.2 `kernel-config.sh` — extend, one script

**One script covers both.** The symbol lists barely diverge. From §3.3, the only
version-dependent entry I found is `KCMP`, which is needed on 6.4 and explicitly
unnecessary after 6.10 — and it is not currently in the list anyway. Everything
else (`AUTOFS_FS` not `AUTOFS4_FS`, the cgroup set, the namespace set) is already
correct for both.

The right shape is one `BUILTIN` list plus a small per-version supplement:

```
BUILTIN="…as now…"
case "$KVER" in
  6.4)  BUILTIN="$BUILTIN KCMP" ;;
esac
```

Two scripts would be wrong. The valuable part of this file is the
set-then-verify-the-same-list discipline, and duplicating it is exactly how the
two copies drift — which is the failure mode the file's own comments were written
to prevent.

### 6.3 State detection — **change**, and this is the real cost

`detect_state()` assumes one kernel tree throughout: one `$KDIR`, one
`kernelrelease`, one set of `ST_*` variables. Two kernels means either two trees
or one tree checked out at different tags.

**Recommend two trees** (`~/ps3-linux-6.4`, `~/ps3-linux-6.18`). One tree with
tag switching breaks `ST_BUILD`, which decides staleness by comparing mtimes of
`drivers/block/ps3disk.c` against `vmlinux` — a checkout rewrites mtimes and the
comparison becomes meaningless.

Three specific things need attention:

**The patch check becomes version-dependent.** Today:

```sh
grep -q 'ps3disk_find_otheros_region' … && grep -q 'offset += bvec.bv_len' …
```

On a 7.x tree the second grep is satisfied *by upstream*, so this happens to
still work — it degrades to testing only for 0002, which is the correct test
there. That is accidental correctness and should be made deliberate: test for the
0002 marker, and treat the bounce-buffer fix as a property of the tree to assert
once, not as evidence that a patch was applied.

**`ROOTFS` and `IMG` are shared, and this is the coupling that hurts.** A rootfs
carries `/lib/modules/<kernel release>` and a `/boot` matching one kernel.
`ST_INSTALL` already checks `[ ! -d "$ROOTFS/lib/modules/$KREL" ]` and would flag
the other kernel's rootfs as stale — correctly, but that means **switching
kernels invalidates the rootfs and forces a rebuild**, which is a debootstrap and
a package install, not a quick step. Either the rootfs becomes per-version (disk
cost, long rebuilds) or module installation becomes additive with careful `/boot`
switching (more state, more ways to ship a mismatched pair).

**The header/phase UI is numbered for one linear pipeline.** Six phases with one
tree. A version choice either sits ahead of phase 1 as a mode selection — the
clean option — or the phase model gains a dimension, which is the messier one.

### 6.4 `docs/` — mostly extend, with one split

Most documentation is version-independent: the region design, the write
protection policy, the naming argument, the migration guide, troubleshooting.

What is version-specific is already concentrated:

- `region-handling.md` §"Porting forward" — is a version-delta section already.
  It becomes a table of "target → required edits", which is roughly §1 of this
  report.
- `kernel-config.md` — the symbol rationale is version-independent; the values
  are not.
- README steps 1–3 name the tree and the version in prose.

**Recommend one `docs/kernel-versions.md`** holding the per-version facts (which
patches apply, which API edits, which symbols, which tree and tag) and leaving
the reasoning inline where it is. The reasoning is what makes those documents
worth having and it does not fork.

### 6.5 What the default should be

**6.4 remains the default until 7.x has booted on hardware and been used.** Then
the default flips, and 6.4 stays selectable for one release cycle before removal.

The reason is that the default is what an unattended user gets, and this tool's
value is that it is known-good on hardware that is expensive to debug and easy to
brick a GameOS install on. A default nobody has booted is not a default.

### 6.6 Would supporting two kernels make the tool worse? Yes — recommend not to

**It would, and I think the answer you floated is the right one.**

The costs are not evenly distributed. `patches/` and `kernel-config.sh` extend
cleanly and cost little. But the rootfs/module coupling (§6.3) means this is not
a tidy two-way switch: it is two trees, potentially two rootfs trees, two module
sets, a `/boot` that must match, and a state machine that currently has one of
each. Every one of those is a way to ship a kernel with the other kernel's
initrd — which is precisely the failure `ST_INSTALL`'s three staleness checks
were written to prevent, and doubling the state doubles the surface.

And the test matrix doubles on hardware where testing is the dominant cost. A
change to `build-rootfs.sh` or `write-image.sh` would need verifying against both
kernels to claim it still works. In practice that means one of them stops being
verified, and an unverified option is worse than no option.

**Recommendation: tag and replace.** Tag the current state on `main` as the
6.4 shipping installer (`v1.0-kernel-6.4`, say), let the 7.x work replace it, and
document the tag in the README for anyone who needs 6.4. That keeps 6.4
retrievable and reproducible at zero ongoing cost, keeps one supported path, and
keeps the state machine that already works.

The case for genuinely supporting both would be that users on unusual firmware
need 6.4 specifically for reasons 7.x cannot serve. I found no evidence of such a
reason — the region behaviour depends on OtherOS++ firmware, not on the kernel
version, and `asm/ps3stor.h` is unchanged. If such a reason emerges, revisit.

---

## What I could not determine

Listed deliberately. An unknown you know about is worth more than a confident
answer that turns out wrong on hardware.

**Whether the target builds.** I did not run a cross-compile. Every API finding
in §1 comes from reading headers and sources at specific tags. Compilation can
fail for reasons no amount of reading finds — a header that no longer gets
included transitively, a `-Werror` warning from a new check. This is cheap to
resolve and should be the first thing done.

**Whether it boots.** I found no report of anyone booting a PS3 on any kernel
≥6.14. Absence of evidence here is weak evidence — few people would publish —
but it means the 2025–2026 PS3 commits are, as far as I can establish,
untested on hardware.

**The final `.config` after `olddefconfig`.** §3.3's defaults come from reading
Kconfig, not from running the tool. `kernel-config.sh`'s verify loop is the
correct instrument and already exists.

**The commit hash of René Rebe's fix.** I established the release by bisecting
tags (absent v6.18, present v6.19) and the date and title from the file's cgit
log. I could not retrieve the hash: `git.kernel.org`'s cgit is behind an Anubis
challenge for the tooling I had, and the googlesource mirror's JSON log endpoint
for `torvalds/linux` did not respond. The release finding does not depend on the
hash, and the tag bisection is stronger evidence than a hash would be.

**Whether `ps3fb`, gelic or `snd_ps3` regressed.** I read commit titles, not
diffs. §5.3 flags them as candidates on the strength of "this subsystem was
refactored in this window", which is a reason to look, not a finding.

**Geoff Levand's intentions.** I found no statement about whether the queue will
resume past `ps3-queue-v6.13`. The plan in §4 deliberately does not depend on it.

**Whether the size budget still fits.** README budgets ~19 MB stripped vmlinux
plus ~15 MB initrd into 256 MB alongside petitboot. I did not build, so I do not
know what 6.18 or 7.x produces. Determinable in the same first build.

---

## Summary

| Question | Answer |
|---|---|
| Does 7.x exist? | Yes — 7.2 mainline, 7.1.8 stable. Numbering went 6.18 → 6.19 → 7.0 |
| Has Levand's tree stopped? | Effectively. Branches reach `ps3-queue-v6.13` (Dec 2024, based on 6.13-rc1); tags stop at v6.4-rc7 |
| Does the platform need forward-porting? | **No.** PS3 support is in mainline and actively maintained (most recent commit 2026-07-28) |
| Is patch 0001 still needed? | **No** — upstream in 6.19, backported to 6.18.44, 6.12.103 and 6.6.151 |
| Does patch 0002 still apply? | Not cleanly. Two localised edits, both already anticipated in `region-handling.md` |
| Does the tag-sharing design still hold? | **Yes, unchanged.** `hctx_may_queue()` still short-circuits at depth 1 |
| Does `ps3_defconfig` still work? | Present; diff from 6.4 is five benign renames; all drivers still selected |
| Biggest platform change? | IBM Cell blade support removed (6.13–6.18) — **does not affect PS3**, which selects the retained `PPC_CELL` |
| Biggest hazard already fixed? | ELFv2 hcall breakage; poisons 6.5–6.8, fixed in code in **6.9** |
| Is Debian ports ppc64 alive? | **Yes** — 92,806 packages, index regenerated 2026-08-18 |
| Recommended target | **6.18.x LTS**, single jump, no intermediate step. 7.1.8 is identical work if 7.x is wanted |
| Estimate | 15–50 h; median ~20–25 h; dominated by hardware bring-up |
| Support both kernels? | **No** — tag 6.4 on `main` and let the new kernel replace it |
