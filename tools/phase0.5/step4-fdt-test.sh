#!/bin/bash
# Phase 0.5 step 4 — does cboot load DTBs from `FDT` file lines?
# This is THE gate for the Phase 2/4 design (can JP4 and JP5 each carry their own DTB?).
#
# ⚠️  UNLIKE steps 1-3, THIS ONE CAN PREVENT THE DOG FROM BOOTING.
# It points the live boot entry at a DTB file. If this cboot can't load DTBs from
# files, boot fails and you need recovery mode (x86 host + USB data cable).
#
# Usage:  ./step4-fdt-test.sh emmc --i-have-recovery
source /home/mi/phase0.5/lib.sh

COPY=${1:-}
case "$COPY" in nvme|emmc) ;; *) echo "usage: $0 nvme|emmc --i-have-recovery"; exit 1 ;; esac

if [ "${2:-}" != "--i-have-recovery" ]; then
  cat <<'EOF'
==========================  STOP  ==========================
step4 has REAL boot-failure risk. Before running it you need:

  1. An x86 Ubuntu host, powered on and reachable.
  2. A plain USB-A -> USB-C DATA cable (the factory black cable is NOT
     required; see PHASE0_RECOVERY_PROCEDURES.md §1).
  3. A COMPLETED recovery-mode drill: host enumerates 0955:7e19 APX after
     `sudo reboot --force forced-recovery`.  [DONE 2026-07-10]
  4. ***The ability to actually REFLASH from recovery***, not just enter it:
     the r32.5.2 BSP unpacked on the host (l4t_initrd_flash.sh present) AND
     the backups (Layer-3 p01.img / CYBERDOG_BACKUP SSD) reachable from it.
     This is a Phase-1 deliverable. Entering RCM (#3) is only half the net;
     without #4 a failed boot is NOT actually recoverable.
  5. Ideally: the next day free.

Why: if cboot cannot load a DTB from a file, the dog will not boot, and the
only way back in is recovery mode. #3 gets you INTO recovery; #4 lets you FIX
it. You need both.

Steps 1-3 carried no such risk. This one does. If you have all of the above:

    ./step4-fdt-test.sh <nvme|emmc> --i-have-recovery

Otherwise stop here and run:  ./revert-all.sh && sudo reboot
============================================================
EOF
  exit 1
fi

case "$COPY" in
  nvme) CONF=$NVME_CONF;  BOOTDIR=/boot; backup_once "$CONF" extlinux.conf.nvme.orig ;;
  emmc) mount_emmc_rw; CONF=$EMMC_CONF; BOOTDIR=$EMMC_MNT/boot; backup_once "$CONF" extlinux.conf.emmc.orig ;;
esac
command -v fdtput >/dev/null 2>&1 || { echo "need fdtput: sudo apt-get install -y device-tree-compiler"; exit 1; }

# Which LABEL is actually booting right now? Put FDT there, not blindly on primary.
CMD=$(cat /proc/cmdline)
if [[ "$CMD" == *cyberdog.test=second* ]]; then TARGET=second
else TARGET=primary; fi
echo "current boot label appears to be: $TARGET  (FDT line will go there)"

# Test DTB = byte-copy of the stock one with only the /model string changed.
sudo cp -a "$BOOTDIR/tegra194-mi-k91.dtb" "$BOOTDIR/dtb-fdttest.dtb"
sudo fdtput -t s "$BOOTDIR/dtb-fdttest.dtb" / model "NVIDIA Jetson Xavier NX Developer Kit FDTTEST"
echo "test DTB model: $(sudo fdtget -t s "$BOOTDIR/dtb-fdttest.dtb" / model)"

if sudo grep -qE '^[[:space:]]*FDT[[:space:]]' "$CONF"; then
  echo "FDT line already present — leaving as is"
else
  edit_conf "$CONF" '
    /^LABEL / { inblk = ($2 == "'"$TARGET"'") }
    { print }
    inblk && $1 == "INITRD" { print "      FDT /boot/dtb-fdttest.dtb" }
  ' "add FDT /boot/dtb-fdttest.dtb to LABEL $TARGET"
fi

touch "$P05/.step4-staged"
[ "$COPY" = emmc ] && umount_emmc

cat <<EOF

Staged. NEXT:  sudo reboot   — then:  ~/phase0.5/check-after-reboot.sh
  /proc/device-tree/model contains FDTTEST => FDT-from-file WORKS => Phase 2/4 safe
  model unchanged                          => FDT ignored => STOP, redesign Phase 2
  dog does not boot                        => power-cycle once; if still dead:
      forced-recovery from x86 (PHASE0_RECOVERY_PROCEDURES.md §1), then ./revert-all.sh

When finished either way:  ~/phase0.5/revert-all.sh && sudo reboot
EOF
