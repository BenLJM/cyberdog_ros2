# Phase 2 kit — TWO-STAGE rescue initrd + dual-boot switching (2026-07-16)

Executes `docs/PHASE2_RUNBOOK.md`. **Redesigned 2026-07-12** after the armed
boot proved cboot's ramdisk buffer silently rejects the original 13 MB
monolithic initrd (QSPI cboot string: "Ramdisk size ... greater than allocated
size"); cboot loaded the stock `/boot/initrd` instead and JP4 booted with the
rescue APPEND. Proven-safe envelope = the stock initrd: **7,236,790 B packed /
~16 MB raw**.

## Two-stage layout

| Artifact | Where | Role |
|---|---|---|
| `initrd-rescue` (stage 1, ~2 MB, strictly < stock envelope, gated) | eMMC APP p1 `/boot/initrd-rescue` — **the only file cboot loads** | static busybox + `/init`: mounts eMMC p1 (never NVMe), sha256-checks the bundle, unpacks it into tmpfs, `switch_root`s into it |
| `rescue-bundle.cpio.gz` (stage 2, ~13 MB, mode 600) | eMMC APP p1 `/boot/rescue-bundle.cpio.gz` | the FULL rescue system (previous monolithic content): sshd w/ real host keys, Wi-Fi userspace + creds, USB gadget, surgery toolchain, `rescue-autorun` gated surgery, `back-to-jp4` |

Stage-1 fallback matrix on any bundle problem (`phase2-surgery.STARTED` is
written by `rescue-autorun` in the same transaction that consumes the arm
flag, before any disk write):

- `SUCCESS` marker on pivot → boot JP4 (surgery already done)
- arm flag intact → defuse flag (rename `.stale`) + boot JP4 (never started)
- `STARTED` without `SUCCESS` → **HOLD**: never touches NVMe; shells on
  ttyTCU0 serial + console only (possible mid-surgery power loss — read
  `/boot/phase2-surgery.log` before doing anything)
- none of the above → boot JP4 (never armed, e.g. rehearsal boot)

Stage-1 logs every decision to kmsg (`rescue-s1:` in dmesg of a same-boot JP4)
and appends to `/boot/phase2-stage1.log` on the pivot.

Accepted residual risks (2026-07-16 review): a corrupted-but-present
`initrd-rescue` makes the kernel fall back to `root=` from cbootargs (plain
JP4 boot — fail-open, chosen deliberately for first-boot safety); a failed
`exec switch_root` panics PID1 (all preconditions pre-checked).

## The one command (owner)

```
sudo bash ~/phase2/arm-and-go.sh
```

rebuild both artifacts → offline-verify (syntax, chroot `sshd -t`, surgery
params, stage-1 embedded sha == bundle sha, busybox zcat/cpio/sha256sum -c
exercised for real, size gates vs stock) → install both (tmp+mv+sha, 600) →
arm one-shot flag + DEFAULT rescue → 30 s countdown → reboot. 10-25 min
offline; success reboots into JP4 with p1/p2/p3; failure stays in rescue with
sshd on Wi-Fi (usual IP, ~2-3 min) or USB `192.168.55.1`.

## Files

- `build-rescue-initrd.sh` — reproducible two-artifact builder (run with sudo)
- `arm-and-go.sh` — canonical build+verify+install+arm+reboot path
- `rescue-autorun.sh`, `rescue-surgery.sh` — surgery chain inside the bundle
- `cyberdog-boot-switch` — DEFAULT flipper (also installed system-wide)
- `check-after-reboot.sh` — post-reboot verdict incl. cboot-fallback vs
  stage-1-fallback disambiguation
- `initrd-rescue`, `rescue-bundle.cpio.gz` + `.sha256` files — the artifacts
- `stage-rescue.sh` — **SUPERSEDED, exits immediately** (LABEL work already
  live since 2026-07-11); kept for history
- `backups/` — pristine extlinux.conf snapshots

## If rescue never comes up on surgery night

Power-cycle → still boots rescue (sticky DEFAULT) → stage-1 matrix above
decides. If truly wedged (HOLD without serial access): forced-recovery + x86
restore of `layer3/p01.img` (`PHASE0_RECOVERY_PROCEDURES.md` §1).
