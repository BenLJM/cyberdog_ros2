# Phase 2 runbook — rescue initrd + offline NVMe dual-rootfs

Executable step-by-step for Phase 2, integrating the **measured** Phase 0.5 results
(2026-07-10). Supersedes the design sketch in `JETPACK5_HUMBLE_PORT_PLAN.md` §10 for
execution purposes. Read `PHASE0_BOOT_MECHANISM_FINDINGS.md` v2 first.

## 0. Hard preconditions (ALL green before touching the disk)

- [ ] **Phase 1 done**: x86 host has the r32.5.2 BSP unpacked (`l4t_initrd_flash.sh`
      present) and the `CYBERDOG_BACKUP` SSD (or its mirror) reachable — i.e. a
      **failed boot is reflashable**, not just enterable (recovery drill already
      passed 2026-07-10).
- [ ] **Phase 0.5 step4 passed**: `LINUX`- and `FDT`-from-file proven to work
      (`./step4-fdt-test.sh emmc --i-have-recovery`). *If step4 fails, this runbook's
      dual-kernel design is invalid — stop and redesign.*
- [ ] Backups verified reachable: Layer 2 (rootfs tar), Layer 3 (`p01.img` = full
      eMMC APP dump — the boot pivot), Layer 3b (QSPI). Rescue drill green.
- [ ] Owner has a free next day.

## 1. Confirmed facts this runbook rests on (Phase 0.5)

- **Boot pivot = eMMC APP p1** `/boot/extlinux/extlinux.conf` (`/dev/mmcblk0p1`).
  The NVMe `/boot/...` copy is decorative — do NOT edit it expecting effect.
- **`DEFAULT` works** → dual-LABEL switching (flip one word, atomic `rename(2)`).
- **File-loading**: `INITRD` from file works today; `LINUX`/`FDT` pending step4.
- eMMC APP p1 is 1.5 GB, ~46 MB used → ample room for `/boot-jp5/`.
- NVMe p1 shrink floor ≈ 18.5 GB (`resize2fs -P`), target 50 GB → wide margin.
- Kernel today loads from the eMMC **kernel partition** (p2), not a file
  (`LABEL primary` has no `LINUX` line). JP4 keeps that; JP5 uses file-load.

## 2. Target layout

```
eMMC APP p1 (/dev/mmcblk0p1, mounted at boot by cboot)
  /boot/Image, /boot/initrd, /boot/tegra194-mi-k91.dtb   ← JP4 (untouched)
  /boot-jp5/{Image, initrd, tegra194-mi-k91.dtb}         ← JP5 (added)
  /boot/initrd-rescue                                    ← rescue initramfs (added)
  /boot/extlinux/extlinux.conf                           ← 3 LABELs + DEFAULT
  /boot/extlinux/extlinux.conf.{jp4,jp5,rescue}-saved    ← canonical copies

NVMe (/dev/nvme0n1)
  p1  50 GB  JP4.5 rootfs (existing, shrunk offline)
  p2  50 GB  JP5 rootfs (new)
  p3  ~17 GB shared /data (new)
```

`extlinux.conf`:

```
TIMEOUT 30
DEFAULT jp4

LABEL jp4
      MENU LABEL JP4.5 (Foxy, stock)
      INITRD /boot/initrd
      APPEND ${cbootargs} root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0

LABEL jp5
      MENU LABEL JP5.1.6 (Humble)
      LINUX  /boot-jp5/Image
      FDT    /boot-jp5/tegra194-mi-k91.dtb
      INITRD /boot-jp5/initrd
      APPEND ${cbootargs} root=/dev/nvme0n1p2 rw rootwait rootfstype=ext4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0 panic=15

LABEL rescue
      MENU LABEL RESCUE (RAM, JP4 kernel, no NVMe mount)
      INITRD /boot/initrd-rescue
      APPEND ${cbootargs} rw rootwait console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0 cyberdog.rescue=1
```

Switching = `cyberdog-boot-switch {jp4|jp5|rescue}` rewrites the `DEFAULT` word via
temp-file + `mv` (atomic). Always target the **eMMC APP p1** copy.

## 3. Build the rescue initrd (materials confirmed on-dog)

All present (verified 2026-07-09): `/bin/busybox`, the stock gzip-cpio initrd as a
template, complete `/opt/nvidia/l4t-usb-device-mode/`, `sshd`.

1. Unpack stock initrd to a workdir; add `busybox`, `dropbear` (or `sshd` + libs),
   and a minimal `/init` that: mounts `/proc`,`/sys`,`/dev`; brings up the USB gadget
   (RNDIS `192.168.55.1` + `ttyGS0`) via the configfs script; starts dropbear; drops
   to a shell. **Never mounts NVMe** → `nvme0n1p1` is free for offline resize.
2. Repack as `/boot/initrd-rescue` on eMMC APP p1.
3. Add the `LABEL rescue` entry (above). Keep `extlinux.conf.rescue-saved`.

## 4. Rehearse switching + rescue BEFORE any disk change

Zero disk risk — all reversible via `cyberdog-boot-switch jp4`:

1. `cyberdog-boot-switch rescue` → reboot → confirm: shell over USB
   (`ssh mi@192.168.55.1` needs host static `192.168.55.100/24` — gadget has no DHCP),
   `mount` shows NO nvme, `cat /proc/cmdline` has `cyberdog.rescue=1`.
2. From rescue, `cyberdog-boot-switch jp4` isn't available (no full userspace) — so
   the rescue initrd must itself accept a "boot jp4 next" action, OR you power-cycle
   and the still-`DEFAULT rescue` boots rescue again → **make rescue's `/init` offer a
   one-key `switch to jp4 + reboot`**. Rehearse that path twice.
3. Dual-kernel sanity (needs step4 already passed): stage a **copy of the JP4 kernel**
   as `/boot-jp5/Image` + its DTB, point `LABEL jp5` at it with `root=/dev/nvme0n1p1`
   (still JP4 rootfs), `cyberdog-boot-switch jp5` → reboot → `uname` identical to JP4.
   Proves `LINUX`+`FDT` file-load on the real entry before JP5 exists.

## 5. Offline partition surgery (from rescue)

1. `cyberdog-boot-switch rescue` → reboot → SSH in over USB gadget.
2. `e2fsck -f /dev/nvme0n1p1`
3. `resize2fs /dev/nvme0n1p1 48G` (leave headroom over the 18.5 GB floor)
4. `parted /dev/nvme0n1`: resizepart 1 → 50 GB; mkpart p2 50→100 GB; mkpart p3 → end.
5. `resize2fs /dev/nvme0n1p1` (grow FS to fill the 50 GB partition exactly)
6. `mkfs.ext4 -L JP5_ROOT /dev/nvme0n1p2`; `mkfs.ext4 -L DATA /dev/nvme0n1p3`
7. `cyberdog-boot-switch jp4` → reboot → JP4 comes up untouched; `lsblk` shows p1/p2/p3.
   Record UUIDs in `MANIFEST.yaml`.

## 6. Recovery matrix (per step)

| If this fails | Recovery |
|---|---|
| Rescue label won't boot | Still on `DEFAULT` → power-cycle boots rescue again; if rescue initrd itself is broken, `cyberdog-boot-switch` can't run → forced-recovery + x86, restore `p01.img` (eMMC APP) → back to a known extlinux |
| jp5 kernel won't boot | `panic=15` auto-reboots; the JP5 initrd's auto-revert hook (review D5) flips DEFAULT→jp4; else power-cycle + it's still DEFAULT jp5 → forced-recovery + x86 edit |
| `resize2fs`/`parted` error mid-way | p1 FS untouched until parted commits; if p1 damaged → Layer 2 rootfs restore (rescue drill proven, 144 s) |
| Whole eMMC APP p1 botched | `dd` restore `layer3/p01.img` via forced-recovery + x86 |
| Total brick | V1.0.0.94 `flashall.sh` (byte-exact factory) |

## 7. Verification gate (before Phase 3)

- [ ] `cyberdog-boot-switch {jp4,rescue}` both boot; switching is atomic across repeated cycles.
- [ ] Offline resize left JP4 fully functional (walks, all services).
- [ ] p2/p3 exist, formatted, UUIDs recorded.
- [ ] Rescue initrd reachable over USB gadget without Wi-Fi.
- [ ] Tag `v0.2-phase2-dualboot`.
