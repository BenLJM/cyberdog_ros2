#!/bin/bash
# Phase 0.5 step 4 — does cboot load DTBs from FDT file lines? (Decides whether
# JP4/JP5 can pair kernels with their own DTBs — gates the whole Phase 2 design.)
# Method: FDT -> byte-copy of the stock DTB with only the /model string changed.
# Usage: ./step4-fdt-test.sh nvme|emmc     ⚠ schedule with the next day free.
source /home/mi/phase0.5/lib.sh
case "${1:-}" in
  nvme) CONF=$NVME_CONF;  BOOTDIR=/boot; backup_once "$CONF" extlinux.conf.nvme.orig ;;
  emmc) mount_emmc_rw; CONF=$EMMC_CONF; BOOTDIR=$EMMC_MNT/boot; backup_once "$CONF" extlinux.conf.emmc.orig ;;
  *) echo "usage: $0 nvme|emmc   (whichever copy is proven live)"; exit 1 ;;
esac
command -v fdtput >/dev/null 2>&1 || { echo "need fdtput:  sudo apt-get install -y device-tree-compiler"; exit 1; }
sudo cp -a "$BOOTDIR/tegra194-mi-k91.dtb" "$BOOTDIR/dtb-fdttest.dtb"
sudo fdtput -t s "$BOOTDIR/dtb-fdttest.dtb" / model "NVIDIA Jetson Xavier NX Developer Kit FDTTEST"
echo "test DTB model: $(sudo fdtget -t s "$BOOTDIR/dtb-fdttest.dtb" / model)"
add_fdt_line "$CONF"
[ "${1}" = emmc ] && umount_emmc
echo
echo "NEXT:  sudo reboot   — then:  tr -d '\\0' </proc/device-tree/model ; echo"
echo "  contains FDTTEST  => FDT-from-file WORKS => Phase 2/4 design is safe"
echo "  unchanged model   => FDT line ignored    => STOP, redesign Phase 2 (review D2.3)"
echo "  dog does not boot => power-cycle; if still stuck: forced-recovery + x86 host"
echo "                       (PHASE0_RECOVERY_PROCEDURES.md §1), then ./revert-all.sh"
echo "When finished either way:  ~/phase0.5/revert-all.sh"
