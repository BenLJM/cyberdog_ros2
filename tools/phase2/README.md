# Phase 2 kit — rescue initrd + dual-boot switching (2026-07-11)

Executes `docs/PHASE2_RUNBOOK.md`. Built and staged **without any reboot**;
the reboot-rehearsal nights are the owner's part.

## What is already done (this kit, 2026-07-11)

| Item | Where | State |
|---|---|---|
| Rescue initrd (26 MB unpacked / 12 MB gz) | `initrd-rescue` + copy on eMMC APP p1 `/boot/initrd-rescue` | built + sha256-verified after copy |
| `LABEL rescue` in live extlinux.conf | eMMC APP p1 (`/dev/mmcblk0p1`) | appended, **DEFAULT still `primary`** |
| Canonical saved copies | `extlinux.conf.{stock,jp4,rescue}-saved` next to live | in place |
| `cyberdog-boot-switch` | `/usr/local/sbin/` | installed; rescue↔primary flip round-trip tested |
| Pristine pre-phase2 backup | `backups/extlinux.conf.pre-phase2` | byte-identical to phase0.5 pristine |

Rescue initrd contents: stock L4T initrd (bash + glibc) + static busybox (254
applets in `/bb`), OpenSSH sshd (key-only root, **the dog's real host keys** —
same fingerprint), USB gadget RNDIS `192.168.55.1` + ACM `ttyGS0` (stock
VID/PID/MACs), surgery tools (`parted sgdisk resize2fs e2fsck mkfs.ext4 tune2fs
dumpe2fs lsblk partprobe wipefs zstd rsync scp`), `back-to-jp4` one-key escape
hatch. `/init` **never mounts the NVMe**; PID1 is busybox init (sysinit =
`/etc/rc.rescue`, sshd + ttyGS0 getty respawned).

Verified offline: `sshd -t` green in chroot, every binary runs against the
initrd's own libs, all scripts `bash -n` clean, authorized_keys byte-identical
to `~mi/.ssh/authorized_keys`.

## Rehearsal night 1 (owner; next day free — runbook §4)

```
sudo cyberdog-boot-switch rescue && sudo reboot
# laptop on the USB cable: static 192.168.55.100/24, then
ssh root@192.168.55.1        # or serial: ttyACM* 115200
cat /proc/cmdline            # expect cyberdog.rescue=1
mount | grep nvme            # expect NOTHING
back-to-jp4                  # escape hatch — rehearse this twice
# after landing in JP4:
./check-after-reboot.sh
```

If rescue never comes up: power-cycle → still boots rescue (DEFAULT) → if truly
wedged, forced-recovery + x86 restore of `layer3/p01.img`
(`PHASE0_RECOVERY_PROCEDURES.md` §1).

## Rehearsal night 2 — dual-kernel LINUX-from-file proof (runbook §4.3)

Stage a **copy of the JP4 kernel** as `/boot-jp5/Image` + its DTB on eMMC APP
p1, add `LABEL jp5` pointing at them with `root=/dev/nvme0n1p1`, flip, reboot,
`uname -a` must match JP4. Directly proves `LINUX`-from-file (Phase 0.5 proved
`FDT`+`INITRD`). Can be folded into night 1 if it goes smoothly — prep the
files during the day with `stage-linux-fdt-proof.sh` (see repo tools/phase2).

## Surgery night (owner; runbook §5) — only after BOTH rehearsals pass

Preconditions: backup SSD attached + verified reachable, rescue SSH rehearsed
twice, next full day free.

## Files

- `build-rescue-initrd.sh` — reproducible builder (run with sudo)
- `stage-rescue.sh` — additive staging onto eMMC APP p1 (gated on pristine state)
- `cyberdog-boot-switch` — DEFAULT flipper (also installed system-wide)
- `check-after-reboot.sh` — post-reboot verdict + next command
- `initrd-rescue`, `initrd-rescue.sha256` — the artifact
- `backups/` — pristine extlinux.conf snapshots
