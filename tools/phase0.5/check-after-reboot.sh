#!/bin/bash
# Phase 0.5 — run after every reboot; prints the verdict + the next action.
set -u
CMD=$(cat /proc/cmdline)
MODEL=$(tr -d '\0' </proc/device-tree/model)
echo "cmdline: $CMD"
echo "model:   $MODEL"
echo "-------------------------------------------------------------------"
say() { echo "==> $*"; }

if [[ "$MODEL" == *FDTTEST* ]]; then
  say "FDT-FROM-FILE WORKS (model override visible) — Phase 2/4 per-OS DTB pairing is SAFE."
  say "Record in PHASE0_BOOT_MECHANISM_FINDINGS.md v2, then run ./revert-all.sh"
fi

if [[ "$CMD" == *cyberdog.test=second* ]]; then
  say "DEFAULT FIELD WORKS on the live copy — the safer dual-LABEL switching design is"
  say "RESURRECTED (April's negative was the confound). Use DEFAULT switching in Phase 2."
  say "Next: ./step4-fdt-test.sh <nvme|emmc>   (on a night with the next day free)"
elif [[ "$CMD" == *cyberdog.src=nvme* ]]; then
  say "cboot reads the NVMe copy — April conclusions STAND (that test edited this file)."
  say "Boot pivot = /boot/extlinux/extlinux.conf on nvme0n1p1."
  say "Next: ./step3-default-test.sh nvme   (re-confirm DEFAULT on record), or skip to step4."
elif [[ "$CMD" == *cyberdog.src=emmcapp* ]]; then
  say "cboot reads the eMMC APP copy — the April tests WERE confounded."
  say "Boot pivot = eMMC APP p1 boot island. All Phase 2 extlinux edits target THAT file."
  say "Next: ./step3-default-test.sh emmc"
else
  NV=$(sudo grep -c 'cyberdog.src=nvme' /boot/extlinux/extlinux.conf 2>/dev/null); NV=${NV:-0}
  say "No marker in cmdline."
  if [ "$NV" -ge 1 ]; then
    say "The NVMe marker IS staged but was NOT picked up => cboot does not read the NVMe copy."
    say "Next: ./step2-emmc-marker.sh"
  else
    say "No marker staged yet. Start with: ./step1-nvme-marker.sh"
  fi
fi
