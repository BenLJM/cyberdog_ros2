# Phase 0 — CyberDog boot mechanism findings (2026-04-25)

Empirical results from non-destructive boot tests on the live `k91` board.
These findings invalidate the original Phase 2 dual-rootfs plan that relied
on extlinux `LABEL` selection and force a redesign to **edit-in-place**.

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
   recovery. From x86, use `l4t_initrd_flash.sh` with the rootfs partition
   mapped over USB. Mount, edit extlinux.conf back to JP4, unmount, done.
   Time: ~30 min.

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
