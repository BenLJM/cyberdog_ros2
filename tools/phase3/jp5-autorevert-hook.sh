#!/bin/bash
# JP5 first-boot auto-revert hook (Phase 3 deliverable, plan §11 / review D5).
#
# Baked into the JP5 initramfs and run EARLY by /init, BEFORE it tries to mount
# root=/dev/nvme0n1p2. If the JP5 rootfs won't mount (the most likely Phase-4
# failure), this restores the eMMC extlinux.conf to the jp4-saved copy and
# reboots — converting a 30-minute USB rescue into a self-healing power-cycle.
# Paired with panic=15 in the JP5 APPEND so a kernel that boots but panics also
# recovers on its own.
#
# Contract with the boot pivot (eMMC APP p1 = /dev/mmcblk0p1):
#   /boot/extlinux/extlinux.conf.jp4-saved   canonical JP4 (DEFAULT primary)
#   /boot/extlinux/extlinux.conf              live file this rewrites
# Sticky-DEFAULT note: DEFAULT is left at jp5 by cyberdog-boot-switch; this hook
# is what flips it back on failure, so an un-recovered panic loop can't strand
# the dog on a broken JP5 — first failed mount reverts and the next boot is JP4.
set -u
PIVOT=/mnt/bootpivot
ROOT_DEV=/dev/nvme0n1p2          # JP5 rootfs
JP4_SAVED_REL=boot/extlinux/extlinux.conf.jp4-saved
LIVE_REL=boot/extlinux/extlinux.conf

klog() { echo "jp5-autorevert: $*" > /dev/kmsg 2>/dev/null; }

revert_and_reboot() {
    klog "REVERT: $* — restoring JP4 extlinux + rebooting"
    mkdir -p "$PIVOT"
    if mount /dev/mmcblk0p1 "$PIVOT" 2>/dev/null; then
        if [ -f "$PIVOT/$JP4_SAVED_REL" ]; then
            cp "$PIVOT/$JP4_SAVED_REL" "$PIVOT/$LIVE_REL.tmp"
            sync
            mv "$PIVOT/$LIVE_REL.tmp" "$PIVOT/$LIVE_REL"   # atomic rename(2)
            sync
            klog "extlinux restored from jp4-saved"
        else
            klog "WARN: jp4-saved copy missing — cannot revert cleanly"
        fi
        umount "$PIVOT" 2>/dev/null || umount -l "$PIVOT" 2>/dev/null
    else
        klog "WARN: could not mount eMMC pivot to revert"
    fi
    sync
    sleep 1
    reboot -f
    # if reboot -f is unavailable, fall through to a hard reset via sysrq
    echo b > /proc/sysrq-trigger 2>/dev/null
    while :; do :; done
}

# --- probe the JP5 rootfs read-only BEFORE the real root mount ---
for i in $(seq 30); do [ -b "$ROOT_DEV" ] && break; sleep 1; done
[ -b "$ROOT_DEV" ] || revert_and_reboot "JP5 root device $ROOT_DEV never appeared"

mkdir -p /mnt/jp5probe
if ! mount -o ro "$ROOT_DEV" /mnt/jp5probe 2>/dev/null; then
    revert_and_reboot "JP5 rootfs failed to mount (fs corrupt / wrong fstype)"
fi
# minimal sanity: a real rootfs has /sbin/init and /etc
if [ ! -e /mnt/jp5probe/sbin/init ] && [ ! -e /mnt/jp5probe/lib/systemd/systemd ]; then
    umount /mnt/jp5probe 2>/dev/null
    revert_and_reboot "JP5 rootfs has no init — not a bootable rootfs"
fi
umount /mnt/jp5probe 2>/dev/null
klog "JP5 rootfs OK — proceeding to normal boot"
exit 0
