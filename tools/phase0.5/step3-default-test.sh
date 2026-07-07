#!/bin/bash
# Phase 0.5 step 3 — re-run the DEFAULT-field test against the copy cboot
# actually reads (proven by steps 1/2). Usage: ./step3-default-test.sh nvme|emmc
source /home/mi/phase0.5/lib.sh
case "${1:-}" in
  nvme) CONF=$NVME_CONF; backup_once "$CONF" extlinux.conf.nvme.orig ;;
  emmc) mount_emmc_rw; CONF=$EMMC_CONF; backup_once "$CONF" extlinux.conf.emmc.orig ;;
  *) echo "usage: $0 nvme|emmc   (whichever copy step 1/2 proved live)"; exit 1 ;;
esac
add_marker "$CONF" second cyberdog.test=second
set_default "$CONF" second
[ "${1}" = emmc ] && umount_emmc
echo
echo "NEXT:  sudo reboot   — then:  ~/phase0.5/check-after-reboot.sh"
echo "  marker in cmdline  => DEFAULT WORKS => dual-LABEL switching design resurrected"
echo "  no marker          => DEFAULT genuinely ignored => edit-in-place design confirmed"
