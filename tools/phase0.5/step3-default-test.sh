#!/bin/bash
# Phase 0.5 step 3 — DEFAULT-field test, on the copy cboot ACTUALLY reads.
#
# SAFETY REVISION (2026-07-10). The stock `LABEL second` carries `LINUX /boot/Image`
# — i.e. it loads the KERNEL FROM A FILE, a cboot behavior that is still UNVERIFIED
# on this board. If DEFAULT works but file-load doesn't, the dog fails to boot, and
# recovery currently requires an x86 host + data cable (owner lost the factory
# recovery cable). So we deliberately DECOUPLE the two questions:
#
#   step3 (this script) — makes `second` structurally IDENTICAL to `primary`
#                         (drops the LINUX line → kernel still comes from the eMMC
#                         kernel partition, exactly as today) and only flips DEFAULT.
#                         Booting `second` is then equivalent to booting `primary`
#                         plus one extra bootarg. ZERO boot risk.
#   step4              — tests file-loading (FDT/LINUX). REAL boot risk. Requires
#                         recovery capability in hand first.
#
# Note `LABEL primary` keeps `INITRD /boot/initrd` and has always booted → cboot CAN
# read files from this filesystem. Only kernel/DTB file-loading remains unproven.
source /home/mi/phase0.5/lib.sh

case "${1:-}" in
  nvme) CONF=$NVME_CONF; backup_once "$CONF" extlinux.conf.nvme.orig ;;
  emmc) mount_emmc_rw; CONF=$EMMC_CONF; backup_once "$CONF" extlinux.conf.emmc.orig ;;
  *) echo "usage: $0 nvme|emmc   (whichever copy step 1/2 proved live — step2 proved: emmc)"; exit 1 ;;
esac

if sudo grep -q 'cyberdog\.test=second' "$CONF"; then
  echo "step3 already staged in $CONF — leaving as is"
else
  # In the `second` block: drop the LINUX file-load line, append the marker.
  edit_conf "$CONF" '
    /^LABEL / { inblk = ($2 == "second") }
    inblk && $1 == "LINUX" { next }
    inblk && $1 == "APPEND" { sub(/[ \t]*$/, ""); $0 = $0 " cyberdog.test=second" }
    { print }
  ' "second := primary-equivalent (drop LINUX file-load) + marker"

  # Post-checks: exactly one marker, and no LINUX line left anywhere.
  [ "$(sudo grep -c 'cyberdog\.test=second' "$CONF")" -eq 1 ] \
    || { echo "POST-CHECK FAIL: marker count != 1 — run ./revert-all.sh"; exit 1; }
  sudo grep -qE '^[[:space:]]*LINUX[[:space:]]' "$CONF" \
    && { echo "POST-CHECK FAIL: a LINUX line still present — run ./revert-all.sh"; exit 1; }
  echo "post-check OK: no LINUX file-load lines remain; second ≡ primary + marker"
fi

set_default "$CONF" second
touch "$P05/.step3-staged"
[ "${1}" = emmc ] && umount_emmc

echo
echo "Staged: DEFAULT=second, and 'second' now boots exactly like 'primary' (+marker)."
echo "NEXT:  sudo reboot   — then:  ~/phase0.5/check-after-reboot.sh"
echo "  marker cyberdog.test=second present => DEFAULT WORKS => dual-LABEL switching viable"
echo "  marker cyberdog.src=emmcapp instead => DEFAULT IGNORED => edit-in-place switching"
echo "  (either way the dog boots normally — this step cannot brick it)"
