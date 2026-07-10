#!/bin/bash
# Phase 0.5 — run after every reboot; prints the verdict + the next action.
set -u
P05=/home/mi/phase0.5
CMD=$(cat /proc/cmdline)
MODEL=$(tr -d '\0' </proc/device-tree/model)
echo "cmdline: $CMD"
echo "model:   $MODEL"
echo "-------------------------------------------------------------------"
say() { echo "==> $*"; }

# --- step4 verdict (FDT-from-file) takes precedence if it was staged ---
if [ -f "$P05/.step4-staged" ]; then
  if [[ "$MODEL" == *FDTTEST* ]]; then
    say "FDT-FROM-FILE WORKS (model override visible) — per-OS DTB pairing is SAFE."
    say "Phase 2/4 may pair each kernel with its own DTB. Record in findings v2."
  else
    say "FDT line was IGNORED (model unchanged) — cboot does NOT load DTBs from files."
    say "=> STOP: Phase 2 must be redesigned (JP4/JP5 cannot each carry their own DTB"
    say "   via FDT; options = DTB-partition swap scripts, or a shared DTB)."
  fi
  say "Then: ./revert-all.sh && sudo reboot"
  exit 0
fi

# --- step3 verdict (DEFAULT field), on whichever copy is live ---
if [[ "$CMD" == *cyberdog.test=second* ]]; then
  say "DEFAULT FIELD WORKS on the live copy — booted LABEL 'second'."
  say "=> The safer DUAL-LABEL switching design is RESURRECTED for Phase 2:"
  say "   keep JP4 and JP5 as two permanent labels; switching = flip one DEFAULT word."
  say "Next (⚠ real boot risk — see below): ./step4-fdt-test.sh emmc"
  say "   Do NOT run step4 until you have recovery capability: x86 host + USB-A→C data"
  say "   cable + a completed recovery-mode drill. Otherwise stop here and ./revert-all.sh"
  exit 0
fi

if [ -f "$P05/.step3-staged" ]; then
  say "DEFAULT FIELD IS IGNORED — and this time it's verified on the copy cboot really"
  say "reads (eMMC APP), so it is a SOLID result, not April's confounded one."
  say "=> Phase 2 switching = edit 'LABEL primary' in place (atomic rename(2))."
  say "Next (⚠ real boot risk): ./step4-fdt-test.sh emmc — only with recovery capability"
  say "   in hand (x86 + data cable + recovery drill). Otherwise: ./revert-all.sh"
  exit 0
fi

# --- step1/step2 verdict (which extlinux.conf does cboot read) ---
if [[ "$CMD" == *cyberdog.src=emmcapp* ]]; then
  say "cboot reads the eMMC APP copy (/dev/mmcblk0p1) — April's tests WERE confounded."
  say "Boot pivot = eMMC APP p1 boot island. ALL Phase 2 extlinux edits target THAT file,"
  say "and JP5 kernel artifacts must live on eMMC APP p1 too (not NVMe /boot)."
  say "Next: ./step3-default-test.sh emmc   (zero boot risk — second ≡ primary + marker)"
elif [[ "$CMD" == *cyberdog.src=nvme* ]]; then
  say "cboot reads the NVMe copy — April's conclusions stand (that test edited this file)."
  say "Boot pivot = /boot/extlinux/extlinux.conf on nvme0n1p1."
  say "Next: ./step3-default-test.sh nvme"
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
