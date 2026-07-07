#!/bin/bash
# Phase 0.5 step 2 — ONLY if step 1's marker did NOT appear in /proc/cmdline.
# Marker on LABEL primary in the eMMC APP (mmcblk0p1) boot-island copy.
source /home/mi/phase0.5/lib.sh
mount_emmc_rw
backup_once "$EMMC_CONF" extlinux.conf.emmc.orig
add_marker "$EMMC_CONF" primary cyberdog.src=emmcapp
umount_emmc
echo
echo "NEXT:  sudo reboot   — after it's back up, run:  ~/phase0.5/check-after-reboot.sh"
