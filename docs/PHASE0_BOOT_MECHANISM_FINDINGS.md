# Phase 0 — CyberDog boot mechanism findings (2026-04-25)

> ⚠️ **CONFOUND DISCOVERED 2026-07-07 — conclusions below are UNSAFE to build on
> until re-tested.** The eMMC APP partition (`/dev/mmcblk0p1`) contains a second
> `/boot` island with its own `extlinux.conf`, textually identical to the NVMe
> copy (`PLAN_REVIEW_2026-07-07.md` §2.3). Every test below edited only the
> **NVMe** copy, and both copies' `LABEL primary` APPEND lines are identical — so
> "primary's APPEND landed in cmdline" cannot tell which file cboot read. The
> negative results (menu doesn't render, `DEFAULT` ignored) have an untested
> alternative explanation: *cboot read the eMMC copy, which was never edited.*
> Also newly relevant: `LABEL primary` has **no `LINUX` line** — the kernel
> actually loads from the eMMC kernel partition (p2, NVDA-wrapped image), so
> kernel/DTB **file** loading is unproven on this cboot too.
> **Re-test procedure: review D2 ("Phase 0.5") — marker bootargs on each copy in
> turn, then a model-string FDT-file test.** Update this file with v2 results.
> (Silver lining: `nvbootctrl` slot findings in Test 3 are NOT confounded —
> `num_slots: 1` / "RootFS A/B not enabled" came from the boot-control HAL
> itself, independent of which extlinux file was read.)

---

# v2 — Phase 0.5 results (2026-07-10, definitive)

The confound is resolved by direct experiment. **cboot reads the eMMC APP copy.**

## v2 Test 1 — marker in the NVMe copy → NOT picked up

`cyberdog.src=nvme` appended to `LABEL primary`'s APPEND in
`/boot/extlinux/extlinux.conf` (NVMe p1). After reboot: **absent** from `/proc/cmdline`.

## v2 Test 2 — marker in the eMMC APP copy → PICKED UP ✅

`cyberdog.src=emmcapp` appended to `LABEL primary`'s APPEND in the eMMC APP copy
(`/dev/mmcblk0p1` → `/boot/extlinux/extlinux.conf`). After reboot:

```
/proc/cmdline: … net.ifnames=0 cyberdog.src=emmcapp
```

**Conclusion: the boot pivot is `/boot/extlinux/extlinux.conf` on the eMMC APP
partition (`mmcblk0p1`). The NVMe copy is decorative — cboot never reads it.**

### What this overturns

Every April conclusion (§ below) was drawn from edits to the **NVMe** copy, which
cboot does not read. "extlinux menu doesn't render", "DEFAULT is ignored" — both are
**void**; they tested a file with no effect on boot. (The `nvbootctrl` A/B findings in
April's Test 3 remain valid — they came from the boot-control HAL, not extlinux.)

### What this proves positively

`LABEL primary` carries **`INITRD /boot/initrd`** (and no `LINUX` line), and has booted
correctly for four years. Therefore:

- **cboot CAN load files from the eMMC APP filesystem** — the initrd is loaded from a
  file on every single boot. File-loading capability is *established*.
- The **kernel** comes from the eMMC kernel partition (p2, NVDA-wrapped), because
  `primary` has no `LINUX` line.
- Still unproven: **`LINUX` from file** and **`FDT` from file** (step 4).

## Design consequences for Phase 2 (supersede the earlier layout)

1. **All extlinux edits target the eMMC APP p1 copy**, not NVMe `/boot`. (A full
   `dd` image of p1 exists as Layer 3 `p01.img`, so file-level edits there are
   recoverable.)
2. **JP5 kernel artifacts must live on eMMC APP p1**, e.g. `/boot-jp5/{Image,initrd,dtb}`
   — *not* on NVMe `/boot-jp5/` as originally planned. p1 is 1.5 GB with only ~46 MB
   used, so there is ample room.
3. The rootfs still lives on NVMe (`root=/dev/nvme0n1p1` today; `p2` for JP5) — kernel
   and initrd load from eMMC, rootfs mounts from NVMe. That split is already how the
   dog boots today.

## v2 Test 3 — DEFAULT field, on the LIVE copy → **WORKS** ✅

⚠️ **Safety revision applied first (2026-07-10).** The stock `LABEL second` carries
`LINUX /boot/Image`, i.e. it would load the **kernel from a file** — one of the two
still-unproven cboot behaviors. Flipping `DEFAULT` to `second` as-is would silently
test kernel-file-loading, and a failure means no boot (owner had no recovery capability
at the time: no x86 attached, factory recovery cable lost, recovery drill not yet done).
So `step3-default-test.sh` was revised to **first strip the `LINUX` line**, making
`second` structurally identical to `primary` (kernel from the kernel partition, initrd
from the same file, same `root=`). It therefore tested **only** the `DEFAULT` field,
with zero boot risk.

**Setup:** in the eMMC APP copy — `LABEL second` stripped of its `LINUX` line, marker
`cyberdog.test=second` on its APPEND, `DEFAULT primary` → `DEFAULT second`.

**Result after reboot:**

```
/proc/cmdline: … net.ifnames=0 cyberdog.test=second
```

**cboot honors the `DEFAULT` field.** It selected `LABEL second` by name and booted it
normally. (April's "DEFAULT is ignored" was an artifact of editing the NVMe copy.)

### This resurrects the dual-LABEL switching design

Phase 2 no longer needs the riskier "rewrite `LABEL primary` in place" scheme:

```
LABEL jp4      INITRD /boot/initrd            (kernel from eMMC kernel partition)
               APPEND … root=/dev/nvme0n1p1
LABEL jp5      LINUX  /boot-jp5/Image         ← needs step-4 result
               FDT    /boot-jp5/tegra194-mi-k91.dtb   ← needs step-4 result
               INITRD /boot-jp5/initrd
               APPEND … root=/dev/nvme0n1p2
DEFAULT jp4                                   ← switching = flip this ONE word
```

Advantages over edit-in-place: both entries persist permanently and independently; the
switch diff is a single word (atomic `rename(2)`); a corrupted edit cannot destroy the
other OS's entry. The failed-JP5-boot auto-revert hook (review D5) becomes simpler too —
the initrd only has to rewrite one word back to `jp4`.

## v2 Test 4 — LINUX / FDT from file — *pending, gated* — **still a hard prerequisite**

Note this is **not optional**: JP5's 5.10 kernel and its DTB cannot come from the eMMC
kernel/DTB partitions without overwriting JP4's (and `nvbootctrl` A/B is decorative, so
slot B is unreachable). Therefore **JP5 must load its kernel + DTB from files**, making
`LINUX`-from-file and `FDT`-from-file mandatory for the whole Phase 2/4 design.

Encouraging prior: `INITRD /boot/initrd` is file-loaded on every boot today, so cboot's
file-loading path demonstrably works; `LINUX`/`FDT` use the same extlinux loader.

**Scheduling decision (2026-07-10): step4 waits for Phase 1.** The recovery-mode drill
below is done (entering RCM works, host sees `0955:7e19`) — but that only proves the
*first* half of the safety net: getting into recovery. The *second* half — actually
repairing a non-booting dog from recovery — needs the x86 host to have the L4T flash
toolchain unpacked (**Xiaomi's `flashall.sh` from the V1.0.0.94 firmware** — the reliable k91-aware reflash; NOT `l4t_initrd_flash.sh`, which does not exist in r32.5.2, only in r35.x) and the Layer-3 `p01.img`
/ backups reachable from that host. Those are Phase 1 deliverables and are **not yet in
place** (the backup SSD is currently on the dog, and the x86 has no BSP unpacked). Since
step4 is the one Phase-0.5 test that can actually prevent boot, it is deferred until the
full recovery capability exists. `step4-fdt-test.sh` hard-gates behind
`--i-have-recovery`; treat that flag as meaning *"I can not only enter RCM but also
reflash from it."*

**RESOLVED 2026-07-11 — step4 preconditions now MET.** On the x86 host (Ben-Nano,
Ubuntu, SSD `phase1-work/`): r32.5.2 BSP unpacked (stock `flash.sh`), and the **V94
firmware unpacked with reflash capability confirmed** — `flashall.sh` drives Xiaomi's
own bundled `tools/kernel_flash/l4t_initrd_flash.sh --flash-only -c
external_storage_layout_nvme.xml --external-device nvme0n1p1` with the k91 board confs.
So BOTH halves of the net exist now: enter-RCM (drill done) + reflash (V94 flashall,
k91-aware, MD5-verified complete package). *Correction: the V94 package DOES ship
`l4t_initrd_flash.sh` — Xiaomi added it even though stock r32.5.2 lacks it.* step4 may be
run when the owner is unhurried and on mains power.

## Phase 0.5 progress (2026-07-10)

- ✅ Test 1/2: cboot reads the **eMMC APP** copy (markers proved it).
- ✅ Test 3: **`DEFAULT` works** → dual-LABEL switching adopted.
- ✅ Recovery-mode drill: `forced-recovery` (triggered over Wi-Fi) → host enumerated
  `0955:7e19` APX. Confirms recovery works **without the lost factory cable**. USB ECM
  link verified (host `enx…` MAC matches the dog's `mac_ecm_h`); note the dog runs **no
  DHCP** on the gadget, so the host needs a static `192.168.55.100/24` if SSH-over-USB is
  wanted — irrelevant to the drill, which uses `lsusb` + Wi-Fi.
- ✅ Steps 1–3 reverted; dog back to stock (`DEFAULT primary`, no markers, kernel 4.9).
- ⏳ Test 4 (LINUX/FDT from file): deferred to after Phase 1 (see above).

## v2 Test 4 — FDT from file — *pending, gated*

Requires recovery capability in hand (x86 host + plain USB-A→C data cable + a completed
recovery-mode drill; see `PHASE0_RECOVERY_PROCEDURES.md` §1). Outcome decides whether
JP4/JP5 can each carry their own DTB.

---

# v1 — April 2026 tests (superseded; kept for the record)

## Tests performed

### Test 1 — extlinux `LABEL second` interactive selection

**Setup**
- `TIMEOUT 10` → `30`
- `LABEL second` (already present in stock config, mirrors primary) → APPEND
  gets a marker bootarg `cyberdog.test=second`
- HDMI monitor + USB keyboard plugged into dog's `extension` USB-C port
- Reboot, expect extlinux menu on HDMI

**Result**
- Dog booted normally to the login prompt
- **No menu rendered on HDMI** during boot (HDMI activates only after kernel
  framebuffer driver loads — well after cboot's selection point)
- USB keyboard inputs not consumed by cboot
- Default `LABEL primary` was used; cmdline did not contain `cyberdog.test=second`

**Implication.** cboot's interactive menu, if it exists, is **serial-console
only** (`/dev/ttyTCU0`). Useless without a USB-TTL adapter, which CyberDog 1
has no exposed pin header for.

### Test 2 — extlinux `DEFAULT` field switching

**Setup**
- `DEFAULT primary` → `DEFAULT second`
- `LABEL second` retains the `cyberdog.test=second` marker
- Reboot

**Result**
- Dog booted normally
- `cat /proc/cmdline` ends with primary's APPEND (no marker)
- `boot.slot_suffix=` is empty (slot A)

**Implication.** cboot **reads** extlinux.conf (proven by `${cbootargs}`
expansion + primary's APPEND landing in cmdline) but **ignores the `DEFAULT`
field**. It always selects `LABEL primary` by name.

### Test 3 — Tegra A/B slot via `nvbootctrl`

**Pre-state (slot A active)**
```
Current bootloader slot: A
Active bootloader slot: A
num_slots: 1                           # only one slot tracked
slot 0: priority=15 retry_count=7 successful=1   (suffix: _a)
slot 1: priority=14 retry_count=7 successful=0   (suffix: empty)
RootFS A/B: not enabled
```

eMMC kernel partitions are physically present and mirrored:
- `/dev/mmcblk0p2` (kernel A) and `p3` (kernel B) have **identical SHA-256**
- `/dev/mmcblk0p4` (kernel-dtb A) and `p5` (kernel-dtb B) **identical SHA-256**

**Setup**
- `sudo nvbootctrl set-active-boot-slot 1` (return code 0, success)
- Reboot

**Post-reboot result**
```
Current bootloader slot: A             # cboot ignored the switch
Active bootloader slot: B              # nvbootctrl-recorded preference
boot.slot_suffix=                      # still empty in /proc/cmdline
nvbootctrl get-current-slot → 0        # slot A booted
```

**Implication.** The Tegra A/B boot-control HAL mechanism is **decorative on
this CyberDog firmware**. cboot ignores the active-slot priority and always
boots from physical slot A. `num_slots: 1` and `RootFS A/B is not enabled`
confirm the firmware was built without functional A/B switching.

## Combined conclusion

The **only viable kernel-switching mechanism** on CyberDog 1's stock cboot
is **editing `/boot/extlinux/extlinux.conf`'s `LABEL primary` definition
in-place** (changing its `LINUX`, `INITRD`, and `APPEND` lines). cboot will
load whatever that label points at on the next boot.

### What this kills

- The original Phase 2 design (NVMe dual-rootfs, switch via `LABEL second`)
- Any plan to leave JP4.5 untouched in slot A while testing JP5 in slot B
- Interactive boot-time slot selection of any kind without a serial cable

### What still works

- Editing `/boot/extlinux/extlinux.conf` primary's `APPEND root=…` to point
  at a different rootfs partition (`nvme0n1p2` for JP5 vs `nvme0n1p1` for JP4)
- Editing primary's `LINUX` and `INITRD` lines to point at different kernel
  images on the same filesystem (e.g. `/boot/Image` vs `/boot-jp5/Image`)
- Phase 0 backups remain fully valid — they're block-level and don't depend
  on the boot mechanism

## Phase 2 redesigned: edit-in-place switching

### Layout

```
NVMe partitions
  /dev/nvme0n1p1  (50 GB)  — JP4.5 rootfs (existing, shrunk in Phase 2)
  /dev/nvme0n1p2  (50 GB)  — JP5 rootfs (new, created in Phase 2)
  /dev/nvme0n1p3  (~17 GB) — shared /data

Boot artefacts on /dev/nvme0n1p1 (JP4.5 side, always mounted by cboot)
  /boot/Image, /boot/initrd, /boot/dtb/...   ← JP4.5 kernel (untouched)
  /boot-jp5/Image, /boot-jp5/initrd, ...     ← JP5 kernel (added later)
  /boot/extlinux/extlinux.conf               ← always points at JP4 OR JP5
  /boot/extlinux/extlinux.conf.jp4-saved     ← canonical JP4 config (backup)
  /boot/extlinux/extlinux.conf.jp5-saved     ← canonical JP5 config (backup)
```

### Switch script (concept)

```bash
# /usr/local/bin/cyberdog-boot-switch
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  jp4)
    sudo cp /boot/extlinux/extlinux.conf.jp4-saved /boot/extlinux/extlinux.conf
    ;;
  jp5)
    sudo cp /boot/extlinux/extlinux.conf.jp5-saved /boot/extlinux/extlinux.conf
    ;;
  *)
    echo "usage: cyberdog-boot-switch {jp4|jp5}"; exit 1 ;;
esac
sync
echo "Switched to $1. Reboot to take effect."
```

### Switching atomicity

`cp` over a target on the same ext4 filesystem with `sync` afterwards is
not atomic against power loss (the file write isn't journaled as a single
transaction). Instead use `mv`:

```bash
sudo cp /boot/extlinux/extlinux.conf.jp5-saved /boot/extlinux/extlinux.conf.tmp
sudo mv /boot/extlinux/extlinux.conf.tmp /boot/extlinux/extlinux.conf
sync
```

`mv` within the same filesystem is `rename(2)`, which is atomic.

### Rollback if JP5 fails to boot

Without a working JP5, you can't run the switch script anymore. Recovery
paths in priority order:

1. **Forced-recovery + x86 host** — boot dog into `forced-recovery` (the
   Xiaomi flashing wiki documents `sudo reboot --force forced-recovery`,
   but this requires the running OS — useless here). Alternative: hold
   power button while connecting USB-C cable to host, dog enters BootROM
   recovery. From x86, reflash: **r35.6.4's `l4t_initrd_flash.sh`** can boot the
   dog into an initrd and expose eMMC/NVMe as USB mass-storage → mount p1, edit
   `extlinux.conf` back, done (fine-grained, loses no data). *(Note: r32.5.2 has
   NO `l4t_initrd_flash.sh` — confirmed 2026-07-11; use the r35.6.4 tool, or the
   nuclear option #3.)* Time: ~30 min if the r35 initrd-flash works against k91.

2. **Layer 2 rootfs tar restore** — full partition rewrite from
   `/mnt/backup/cyberdog-2026-04/layer2/rootfs-nvme.tar.zst`. Time: ~45 min.
   Procedure in `PHASE0_RECOVERY_PROCEDURES.md` §3.

3. **Layer 4 nuclear option** — JP4.5.1 BSP + Xiaomi `flashall.sh`.
   Time: 2–3 h. Procedure in `PHASE0_RECOVERY_PROCEDURES.md` §5.

### What we lose vs. original plan

- **No instant-rollback "reboot + pick old slot from menu"**. Each test of
  a new JP5 build that fails to boot costs at least ~30 min recovery.
- This raises the cost of Phase 4 (first JP5 boot) significantly. We must
  be more thorough about kernel sanity (initrd module list, root partition
  spec, console config) before each flash attempt.

### What we gain

- **Simpler mental model**: there's only one boot path at any given time.
- **No slot synchronisation risk**: we can't accidentally desync A vs B.
- **Phase 0 backup strategy unchanged**: all 4 layers we already captured
  apply identically.

## Action items affected

1. Update [`JETPACK5_HUMBLE_PORT_PLAN.md`](./JETPACK5_HUMBLE_PORT_PLAN.md)
   §10 "Phase 2" to reference this finding and the new edit-in-place flow.
2. Drop the "non-destructive `LABEL second` boot test" gate from Phase 0
   prerequisites — it's been performed and the answer is "doesn't work".
3. Add a Phase 4 prerequisite: practice the `cyberdog-boot-switch` flow
   end-to-end using two **identical** kernel paths (e.g. `/boot/Image` and
   `/boot/Image.copy`) before introducing the actual JP5 kernel.
4. Increase rigour on the JP5 kernel build (Phase 3): the `athena_defconfig`
   synthesis and `initrd` module bake-in must be flawless before first boot,
   because failed boot cost is now ~30 min recovery instead of 1-min reboot.
