# tools/phase4 — first JP5 boot (plan §12)

Built after the 2026-07-19 retrospective (see `docs/RETROSPECTIVE-2026-07-19.md`
findings H1/H4/H5): the JP5 initramfs is the safety net for the first boot,
and it has to respect this cboot's SILENT ~7.2 MB ramdisk ceiling
(PHASE2_RUNBOOK §3b) or the net vanishes without an error message.

## Files

| file | what |
|------|------|
| `build-jp5-initrd.sh` | builds `jp5-initrd`: static busybox + gadget console (RNDIS 192.168.55.1 + ttyGS0) + auto-revert guard + switch_root to nvme0n1p2. Hard size gates: packed < 7,236,790 B, raw < 16 MiB. No modules needed — boot-critical drivers are `=y`. |
| `jp5-boot-ok.sh` / `jp5-boot-ok.service` | installed INTO the JP5 rootfs during staging; clears `/boot/jp5-boot-attempts` on the eMMC pivot once multi-user.target is reached. Without it, the initrd guard reverts to JP4 after 3 attempts — that is the design, not a bug. |

The guard itself lives at `tools/phase3/jp5-autorevert-hook.sh` (canonical
copy; the initrd builder copies it in as `/sbin/jp5-autorevert-hook`).

## Build (Mac, cyberdog-kbuild container)

```sh
docker run --rm \
  -v ~/projects/cyberdog/build:/work \
  -v ~/projects/cyberdog/cyberdog_ros2:/repo \
  cyberdog-kbuild bash /repo/tools/phase4/build-jp5-initrd.sh
# output: build/out/final/jp5-initrd (+ .sha256), alongside the kernel artifacts
```

Fixed build order: `full-build.sh` WIPES `out/final` (by design —
stale-artifact protection) — always re-run `build-jp5-initrd.sh` after every
`full-build.sh` run.

Staging renames (names must match the runbook §2 stanza verbatim):
`Image` → `/boot-jp5/Image`, `jp5-initrd` → `/boot-jp5/initrd`,
`tegra194-p3668-0001-p2151-0000.dtb` → `/boot-jp5/tegra194-mi-k91.dtb` —
the DTB copy must OVERWRITE the stale Jul-11 JP4 byte-copy DTB already sitting
at that path on the dog.

Staging re-check: the initrd size gate (packed < 7,236,790 B, raw < 16 MiB)
AND sha256 of the staged file vs `jp5-initrd.sha256`. Also apply the plan §7
mask/hold rule in the p2 rootfs before first boot (`apt-mark hold
nvidia-l4t-bootloader nvidia-l4t-initrd nvidia-l4t-xusb-firmware`).

## Phase-4 sequencing reminders (full list in plan §12 / HANDOFF)

1. **Stanza rewrite FIRST** (plan §12 ③): rewrite the whole `LABEL jp5`
   stanza (LINUX/FDT/INITRD → `/boot-jp5/`, `root=/dev/nvme0n1p2`,
   `panic=15`); then REGENERATE the three `*-saved` copies on the pivot; then
   `boot-switch rescue` once to prove the escape hatch still boots. Do NOT arm
   jp5 before this — the stanza live today is the 2026-07-11 proof-mode
   placeholder (JP4 kernel, `root=/dev/nvme0n1p1`, guard not even loaded), so
   arming it as-is proves nothing and reverts nothing.
2. **Empty-p2 rehearsal, BEFORE rsyncing the rootfs** (prerequisite: stanza
   rewritten & `*-saved` regenerated per plan §12 ③): with p2 still an empty
   filesystem, arm LABEL jp5 and boot once — the guard's init-check fails
   naturally and must flip DEFAULT back to jp4. This one boot proves
   kernel-from-file, initrd identity (check `chosen/linux,initrd-*` size in
   dmesg ≙ `jp5-initrd`, NOT 7,236,790 B = stock), and the revert path.
   `bogus root=` does NOT work as a drill — the guard probes p2 directly, not
   `root=`. **Only after this rehearsal passes do you switch to jp5 for
   real.**
3. First boots are HOT reboots with the USB cable attached the whole time
   (Phase-2-proven safe). Cold power-on: power first, cable second
   (RCM/APX 0955:7e19 was once triggered by cold boot with cable attached —
   that same behaviour is the Path-B recovery trigger, rehearse it on purpose
   at the start of the night).
