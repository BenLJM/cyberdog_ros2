# Phase 2 runbook — rescue initrd + offline NVMe dual-rootfs

Executable step-by-step for Phase 2, integrating the **measured** Phase 0.5 results
(2026-07-10/11). Supersedes the design sketch in `JETPACK5_HUMBLE_PORT_PLAN.md` §10
for execution purposes. Read `PHASE0_BOOT_MECHANISM_FINDINGS.md` v2 first.

> **Status 2026-07-11: §3 built + §4 fully staged, zero reboots so far.** Rescue
> initrd built, verified offline, and installed on the pivot; `LABEL rescue` +
> `LABEL jp5` (LINUX/FDT-proof) live with `DEFAULT primary` untouched;
> `cyberdog-boot-switch` installed and flip-tested round-trip on the live pivot.
> Kit: `/home/mi/phase2/` (= repo `tools/phase2/`). Remaining: §4 reboot rehearsals
> (owner nights) → §5 surgery (owner night, next day free).

## 0. Hard preconditions (ALL green before touching the disk)

- [x] **Phase 1 reflash capability CONFIRMED (2026-07-11, commit 96b0b62)**: RCM
      drill passed 2026-07-10 with a plain USB cable (`0955:7e19`); **V1.0.0.94's own
      `flashall.sh` → Xiaomi-bundled `l4t_initrd_flash.sh` verified k91-aware**
      (board confs present) — see `PHASE0_LAYER4_RUNBOOK.md` sign-off. Reliability
      order stands: (a) Xiaomi `flashall.sh` — nuclear, byte-exact factory; (b)
      r35.6.4 `l4t_initrd_flash.sh` — fine-grained. *(r32.5.2 BSP has only
      traditional `flash.sh` + NFS scripts.)*
- [x] **Phase 0.5 step4 PASSED 2026-07-11**: `FDT`-from-file directly proven
      (model-string test); `INITRD`-from-file proven (stock uses it). `LINUX`-from-file
      strongly inferred (same file-loader) — **directly proven by §4.3 below, before
      any disk change**. *If §4.3 fails, stop and redesign — no surgery.*
- [ ] Backups verified reachable **on surgery night**: SSD attached, Layer 2 (rootfs
      tar), Layer 3 (`p01.img` = full eMMC APP dump — the boot pivot), Layer 3b
      (QSPI) spot-checked. Rescue drill green. *(SSD was not attached 2026-07-11.)*
- [ ] Owner has a free next day.

## 1. Confirmed facts this runbook rests on (Phase 0.5)

- **Boot pivot = eMMC APP p1** `/boot/extlinux/extlinux.conf` (`/dev/mmcblk0p1`).
  The NVMe `/boot/...` copy is decorative — do NOT edit it expecting effect.
- **`DEFAULT` works** → dual-LABEL switching (flip one word, atomic `rename(2)`).
- **File-loading**: `INITRD` from file works today; **`FDT` from file PROVEN
  2026-07-11** (Test 4); `LINUX` inferred — §4.3 proves it directly.
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

*Interim state (2026-07-11):* live file still uses stock `LABEL primary` (=jp4;
`cyberdog-boot-switch jp4` maps to it automatically), plus staged `LABEL rescue`
and `LABEL jp5` — the latter currently in **proof mode** (JP4 kernel copy,
`root=/dev/nvme0n1p1`) until §4.3 passes and real JP5 artifacts replace it. The
full rename to the layout above happens with the §5 surgery.

## 3. Build the rescue initrd — **DONE 2026-07-11** (zero reboots)

Built, verified offline, and installed by `tools/phase2/build-rescue-initrd.sh` +
`stage-rescue.sh`. Design deltas vs the original sketch, all deliberate:

- **OpenSSH `sshd` instead of dropbear** — the laptop's key is ed25519, which
  dropbear 2017.75 (bionic) can't verify; sshd also brings `internal-sftp` (file
  transfer) and reuses **the dog's real host keys** → same fingerprint, no
  known_hosts churn. Key-only root login, `authorized_keys` = `~mi/.ssh/`.
- Base = the **live eMMC APP p1 initrd** (bash + glibc, 16 MB) + static busybox
  (254 applets in `/bb`) + surgery tools (`parted sgdisk resize2fs e2fsck mkfs.ext4
  tune2fs dumpe2fs lsblk partprobe wipefs zstd rsync scp` with lib closures).
- Gadget = configfs replica of stock `nv-l4t-usb-device-mode` (same VID/PID/MACs):
  RNDIS `usb0` 192.168.55.1 + ACM `ttyGS0` getty. All gadget kernel bits are `=y`
  in the stock 4.9 config — no modules needed in the initrd.
- `/init` mounts only proc/sys/dev(+configfs/devpts/tmpfs), **never touches NVMe**,
  then hands PID1 to busybox init (zombie reaping; sshd + getty respawn).
- One-key escape hatch **`back-to-jp4`** (= `rescue-boot-switch jp4` + `reboot -f`).

Verified offline (no reboot): `sshd -t` green in chroot; every binary runs against
the initrd's own libs; scripts `bash -n` clean; installed sha256 matches build.
Artifact: 26 MB unpacked / 12 MB gz at `/boot/initrd-rescue` on the pivot;
`LABEL rescue` live; `extlinux.conf.{stock,jp4,rescue}-saved` in place.

### 3b. TWO-STAGE redesign (2026-07-12 incident → fixed 2026-07-16/17)

The first armed boot (2026-07-12 00:43) proved **cboot's ramdisk buffer cannot
hold the 13 MB monolithic initrd**: cboot silently loaded the stock
`/boot/initrd` instead (DT `chosen/linux,initrd-*` = exactly 7,236,790 B =
stock size; QSPI cboot strings contain `Ramdisk size ... greater than
allocated size`) while still applying the rescue `APPEND` — the dog booted
plain JP4 with `cyberdog.rescue=1` in cmdline and the surgery never started
(flag unconsumed; fail-open). Proven-safe envelope = the stock initrd:
**7,236,790 B packed / ~16 MB raw**.

Fix: split into **stage-1 loader** (`/boot/initrd-rescue`, ~0.9 MB busybox +
`/init`; the only file cboot loads; hard size-gated `< stock` at build AND
arm time) + **stage-2 bundle** (`/boot/rescue-bundle.cpio.gz`, the full
previous rescue system, sha256-pinned inside stage-1, unpacked into a tmpfs
and `switch_root`ed into). Stage-1 fallback matrix keyed on
`phase2-surgery.STARTED` (written by `rescue-autorun` in the same verified
transaction that consumes the arm flag): `SUCCESS`→JP4, flag intact→defuse to
`.stale`+JP4, `STARTED` w/o `SUCCESS`→HOLD (never touches NVMe; shells on
ttyTCU0+console), none→JP4. Decisions logged to kmsg (`rescue-s1:`) and
`/boot/phase2-stage1.log` on the pivot. Two adversarial multi-agent review
rounds (24 findings) preceded re-arming; notable kills: **`mkfs.ext4` was
missing from the bundle since day one** (gate_tools would have aborted every
armed surgery at the gates) and a dangling-symlink `[ -x /newroot/sbin/init ]`
check that would have inverted every JP4 fallback into HOLD. Details:
`tools/phase2/README.md`.

## 4. Rehearse switching + rescue BEFORE any disk change

**Staging DONE 2026-07-11 (no reboots yet):** `cyberdog-boot-switch` installed to
`/usr/local/sbin` and **flip round-trip tested on the live pivot** (rescue →
primary, final file byte-identical to `extlinux.conf.jp4-saved`); §4.3's proof
files staged by `tools/phase2/stage-linux-fdt-proof.sh` (`/boot-jp5/{Image,dtb}` =
byte-copies of JP4's, `LABEL jp5` live). **Rehearsals 4.1–4.3 fold into ONE owner
evening (~5–6 reboots), rescue-first** — the escape hatch gets proven before
anything else depends on it. Next-day-free is only required for §5, not for this.

Zero disk risk — all reversible via `cyberdog-boot-switch jp4`:

1. `sudo cyberdog-boot-switch rescue` → reboot → confirm: `ssh root@192.168.55.1`
   (laptop static `192.168.55.100/24` — gadget has no DHCP; serial fallback =
   ttyACM 115200), `mount` shows NO nvme, `/proc/cmdline` has `cyberdog.rescue=1`.
2. In rescue run **`back-to-jp4`** (one key, built into the initrd) → lands in JP4.
   Rehearse the rescue⇄jp4 cycle **twice**. Note: `DEFAULT` is deliberately
   **sticky** (no auto-flip-back): if surgery is ever interrupted mid-resize, a
   power-cycle must land back in rescue, NOT boot JP4 onto a half-shrunk root.
3. Dual-kernel LINUX-from-file proof (files already staged): `sudo
   cyberdog-boot-switch jp5` → reboot → normal JP4 boot, `uname -a` identical.
   Proves `LINUX`+`FDT` file-load on the real entry before JP5 exists. Then
   `sudo cyberdog-boot-switch primary` → reboot. Run
   `~/phase2/check-after-reboot.sh` after every landing for the verdict + next step.

## 5. Offline partition surgery (from rescue) — **sector-exact**

> **⚠ Unit bug fixed 2026-07-11 (multi-agent review).** The previous steps said
> `resize2fs 48G` (GiB = 51,539,607,552 B) then `parted resizepart 1 → 50 GB`
> (SI = 50,000,000,000 B) — the partition end would land **~1.5 GB inside the
> filesystem** and truncate it. Never mix units here. The procedure below uses
> 4K-block counts for resize2fs and explicit sectors for parted, precomputed from
> the measured geometry (2026-07-11): disk 250,069,680 × 512 B sectors; p1 start
> = sector 40; FS = 31,258,368 × 4K blocks (fills p1 exactly); ~9.3 M blocks used.

Targets: p1 ends at sector **104,859,647** (≈50.0 GiB, 1 MiB-aligned end+1);
p2 = sectors **104,859,648–209,717,247** (50 GiB, aligned); p3 = **209,717,248–end**
(≈19.2 GiB).

1. `cyberdog-boot-switch rescue` → reboot → SSH in over USB gadget.
   Confirm NOTHING mounts the NVMe: `grep nvme /proc/mounts` → empty.
2. `e2fsck -f /dev/nvme0n1p1`
3. `resize2fs /dev/nvme0n1p1 12582912` — **4K blocks** = exactly 48 GiB; no unit
   ambiguity. (Floor is ~18.5 GB used; 48 GiB leaves wide margin.)
4. Verify before touching the partition table:
   `dumpe2fs -h /dev/nvme0n1p1 | grep 'Block count'` → must print **12582912**.
   FS bytes = 12,582,912 × 4,096 = 51,539,607,552 ≤ new p1 bytes
   = (104,859,647 − 40 + 1) × 512 = 53,688,119,296 → **2.0 GiB headroom ✓**
5. `parted /dev/nvme0n1` → `unit s` → `resizepart 1 104859647s` (answer Yes to the
   shrink warning) → `mkpart JP5_ROOT ext4 104859648s 209717247s`
   → `mkpart DATA ext4 209717248s 100%` → `quit`; then `partprobe /dev/nvme0n1`.
6. `resize2fs /dev/nvme0n1p1` (grow FS to fill the new p1 exactly), then
   **`e2fsck -f /dev/nvme0n1p1` again — must be clean before rebooting.**
7. `mkfs.ext4 -L JP5_ROOT /dev/nvme0n1p2`; `mkfs.ext4 -L DATA /dev/nvme0n1p3`
8. `back-to-jp4` → JP4 comes up untouched; `lsblk` shows p1/p2/p3.
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

- [x] `cyberdog-boot-switch {jp4,rescue}` both boot; switching is atomic across
      repeated cycles. *(2026-07-17..19: primary↔rescue flipped 6+ times through
      arm/disarm/rehearsal/surgery; every landing matched the DEFAULT set.
      NOTE: rescue boots ONLY since the `LINUX /boot/Image` line was added —
      without a LINUX line this cboot ignores extlinux INITRD entirely, §3b.)*
- [x] Offline resize left JP4 fully functional (all services; boots clean, only
      the pre-existing stock unit failures). *(Walk test still owner's to run —
      services incl. locomotion stack start normally.)*
- [x] p2/p3 exist, formatted, UUIDs recorded. *(docs/MANIFEST.yaml, 2026-07-19)*
- [x] Rescue initrd reachable over USB gadget without Wi-Fi. *(2026-07-18/19:
      entire surgery night driven over ttyACM serial + RNDIS after Wi-Fi
      dropped; gadget survived the full session.)*
- [x] Tag `v0.1-phase2-dualboot` (name per plan §21's tag ladder).
