#!/bin/bash
# Phase 0.5 — restore every touched file from the pristine backups.
set -u
source /home/mi/phase0.5/lib.sh 2>/dev/null || { P05=/home/mi/phase0.5; BK=$P05/backups; NVME_CONF=/boot/extlinux/extlinux.conf; EMMC_MNT=/mnt/emmc-app; EMMC_CONF=$EMMC_MNT/boot/extlinux/extlinux.conf; }
if [ -f "$BK/extlinux.conf.nvme.orig" ]; then
  sudo cp "$BK/extlinux.conf.nvme.orig" "$NVME_CONF.p05tmp" && sudo mv "$NVME_CONF.p05tmp" "$NVME_CONF"
  echo "restored NVMe extlinux.conf"
fi
sudo rm -f /boot/dtb-fdttest.dtb
if [ -f "$BK/extlinux.conf.emmc.orig" ]; then
  sudo mkdir -p "$EMMC_MNT"; mountpoint -q "$EMMC_MNT" || sudo mount /dev/mmcblk0p1 "$EMMC_MNT"
  sudo cp "$BK/extlinux.conf.emmc.orig" "$EMMC_CONF.p05tmp" && sudo mv "$EMMC_CONF.p05tmp" "$EMMC_CONF"
  sudo rm -f "$EMMC_MNT/boot/dtb-fdttest.dtb"
  sync; sudo umount "$EMMC_MNT"
  echo "restored eMMC APP extlinux.conf"
fi
sync
echo "revert complete — next boot is stock. (Backups kept in $BK for the record.)"
