# Phase 0.5 — boot-path disambiguation kit (2026-07-07)

Why this exists: `PLAN_REVIEW_2026-07-07.md` §2.3/§2.4 + D2. Two copies of
`extlinux.conf` exist (NVMe p1 and the eMMC APP p1 boot island); the April tests
edited only the NVMe copy, so "DEFAULT is ignored" is unproven. Also, kernel/DTB
loading from *files* has never been observed on this cboot (stock boots the eMMC
kernel partition). These 3–4 reboots settle the whole Phase 2 design.

**Safety:** every script backs up the pristine file to `backups/` on first touch,
edits atomically (`rename(2)`), and asserts the result before installing it.
`./revert-all.sh` restores everything. Steps 1–3 point at the same kernel/rootfs
as stock — worst realistic case is a normal boot without the marker. Step 4 (FDT)
is the only one with real boot-failure risk: **run it on a night with the next day
free**; recovery = power-cycle, then forced-recovery + x86 host if truly stuck
(`PHASE0_RECOVERY_PROCEDURES.md` §1, ~30 min).

## Procedure

```
./step1-nvme-marker.sh      # marker in NVMe copy
sudo reboot
./check-after-reboot.sh     # tells you the verdict + exact next command

# only if step 1's marker did not appear:
./step2-emmc-marker.sh
sudo reboot
./check-after-reboot.sh

./step3-default-test.sh nvme|emmc     # DEFAULT-field retest on the LIVE copy
sudo reboot
./check-after-reboot.sh

./step4-fdt-test.sh nvme|emmc         # FDT-from-file test (next day free!)
sudo reboot
./check-after-reboot.sh

./revert-all.sh             # always finish with this
sudo reboot                 # back to 100% stock
```

## Outcomes → Phase 2 design

| Result | Meaning |
|---|---|
| step1 marker visible | Pivot = NVMe `/boot`; April findings stand; edit-in-place design |
| step2 marker visible | Pivot = eMMC APP p1; April tests were confounded; Phase 2 edits target the island |
| step3 marker visible | `DEFAULT` works ⇒ resurrect the safer dual-LABEL switching |
| step4 model shows FDTTEST | cboot loads DTB files ⇒ per-OS DTB pairing safe ⇒ Phase 2/4 proceed |
| step4 model unchanged | FDT line ignored ⇒ **STOP** — redesign Phase 2 before any surgery |

Write the results into `docs/PHASE0_BOOT_MECHANISM_FINDINGS.md` (v2 section) and
update the plan §10 accordingly.
