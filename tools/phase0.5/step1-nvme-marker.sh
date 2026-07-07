#!/bin/bash
# Phase 0.5 step 1 — marker on LABEL primary in the NVMe copy ONLY.
# Determines whether cboot reads /boot/extlinux/extlinux.conf on nvme0n1p1.
source /home/mi/phase0.5/lib.sh
backup_once "$NVME_CONF" extlinux.conf.nvme.orig
add_marker "$NVME_CONF" primary cyberdog.src=nvme
echo
echo "NEXT:  sudo reboot   — after it's back up, run:  ~/phase0.5/check-after-reboot.sh"
