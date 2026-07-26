#!/bin/sh
# JP5 first-boot auto-revert guard (plan §11/§12, review D5; rewritten after the
# 2026-07-19 retrospective — see RETROSPECTIVE H5 / repo-consistency findings).
#
# Runs inside the JP5 initramfs, invoked by /init AFTER devtmpfs/proc/sysfs are
# mounted and the USB gadget console is up (see tools/phase4/build-jp5-initrd.sh).
# busybox ash only — no bashisms.
#
# WHAT IT PROTECTS AGAINST (honest coverage statement):
#   1. JP5 rootfs missing / unmountable / no init  -> immediate revert to JP4.
#   2. Rootfs mounts but boot later fails (driver panic, systemd crash, kernel
#      panic + panic=15 reboot loop): every initrd pass increments a boot-attempt
#      counter on the eMMC pivot; the counter is cleared ONLY by
#      jp5-boot-ok.service after a successful multi-user boot. More than
#      MAX_ATTEMPTS passes without a success -> revert. This is what breaks the
#      panic loop — the mount probe alone cannot (it passes every time).
#   NOT covered: a kernel that dies before reaching this initrd (cboot loads the
#   wrong initrd / kernel hangs pre-initramfs). That window is why Phase 4 keeps
#   panic=15 in APPEND, rehearses on an EMPTY p2 first, and verifies the loaded
#   initrd identity via DT chosen/linux,initrd-* size (PHASE2_RUNBOOK §3b).
#
# Failure of the revert itself (pivot unmountable / jp4-saved missing) does NOT
# blind-reboot into the same wall: it HOLDs with shells on the gadget console
# (ttyGS0) + /dev/console so the dog stays reachable over USB.
#
# Contract with the boot pivot (eMMC APP p1 = /dev/mmcblk0p1):
#   /boot/extlinux/extlinux.conf.jp4-saved   canonical JP4 (DEFAULT primary/jp4)
#   /boot/extlinux/extlinux.conf             live file this rewrites on revert
#   /boot/jp5-boot-attempts                  counter (cleared by jp5-boot-ok)
#   /boot/jp5-revert.log                     post-mortem breadcrumbs
set -u
export PATH=/bb:/bin:/sbin:/usr/bin:/usr/sbin

PIVOT=/mnt/bootpivot
PIVOT_DEV=/dev/mmcblk0p1
ROOT_DEV=/dev/nvme0n1p2          # JP5 rootfs
JP4_SAVED_REL=boot/extlinux/extlinux.conf.jp4-saved
LIVE_REL=boot/extlinux/extlinux.conf
ATTEMPTS_REL=boot/jp5-boot-attempts
RLOG_REL=boot/jp5-revert.log
MAX_ATTEMPTS=3

klog() { echo "jp5-autorevert: $*" > /dev/kmsg 2>/dev/null; echo "jp5-autorevert: $*" > /dev/console 2>/dev/null; }

plog() {  # breadcrumb on the pivot for post-mortem from JP4
    klog "$*"
    if [ -w "$PIVOT/boot" ]; then
        echo "$(date 2>/dev/null) $*" >> "$PIVOT/$RLOG_REL" 2>/dev/null
        sync
    fi
}

HOLD() {  # last resort: stay reachable instead of blind-reboot-looping
    klog "HOLD: $* — dropping to shells on ttyGS0 (USB gadget) + console"
    # setsid+cttyhack give the shell a controlling TTY (job control, Ctrl-C) —
    # without them one wedged command kills the only rescue channel.
    if [ -c /dev/ttyGS0 ]; then
        while :; do setsid cttyhack sh < /dev/ttyGS0 > /dev/ttyGS0 2>&1; sleep 1; done &
    fi
    while :; do setsid cttyhack sh < /dev/console > /dev/console 2>&1; sleep 1; done
}

revert_and_reboot() {
    plog "REVERT: $* — restoring JP4 extlinux + rebooting [initrd: $(cat /etc/jp5-initrd.build 2>/dev/null || echo unknown)]"
    # Every write below is VERIFIED (2026-07-19 review): a read-only / dying
    # eMMC must land in HOLD, never in a lying "restored" + reboot loop.
    if [ ! -f "$PIVOT/$JP4_SAVED_REL" ]; then
        HOLD "jp4-saved copy missing — cannot revert cleanly, refusing to loop"
    fi
    # sanity-check the SOURCE before touching the live file — restoring an
    # empty/truncated jp4-saved would leave cboot with no config at all
    if ! grep -q "^DEFAULT" "$PIVOT/$JP4_SAVED_REL" 2>/dev/null; then
        HOLD "jp4-saved has no DEFAULT line — refusing to restore garbage"
    fi
    cp "$PIVOT/$JP4_SAVED_REL" "$PIVOT/$LIVE_REL.tmp" \
        || HOLD "cp to $LIVE_REL.tmp failed (pivot read-only or dying?)"
    sync
    mv "$PIVOT/$LIVE_REL.tmp" "$PIVOT/$LIVE_REL" \
        || HOLD "mv onto $LIVE_REL failed (pivot read-only or dying?)"   # atomic rename(2)
    sync
    # prove the restored content actually took (catches silent ro / ENOSPC
    # truncation; page-cache read-back — the syncs above are what make it real)
    cmp -s "$PIVOT/$JP4_SAVED_REL" "$PIVOT/$LIVE_REL" \
        || HOLD "restored extlinux.conf does not match jp4-saved — refusing to reboot into it"
    # archive the counter so the next JP5 attempt starts fresh
    [ -f "$PIVOT/$ATTEMPTS_REL" ] && mv "$PIVOT/$ATTEMPTS_REL" "$PIVOT/$ATTEMPTS_REL.reverted" 2>/dev/null
    sync
    plog "extlinux restored from jp4-saved (verified) — next boot is JP4"
    umount "$PIVOT" 2>/dev/null || umount -l "$PIVOT" 2>/dev/null
    sync
    sleep 1
    reboot -f
    echo b > /proc/sysrq-trigger 2>/dev/null
    while :; do :; done
}

# --- 1. mount the eMMC pivot (wait for the device; HOLD if truly absent) ---
i=0
while [ "$i" -lt 30 ]; do [ -b "$PIVOT_DEV" ] && break; sleep 1; i=$((i+1)); done
[ -b "$PIVOT_DEV" ] || HOLD "$PIVOT_DEV never appeared — cannot reach extlinux to revert"
mkdir -p "$PIVOT"
mount "$PIVOT_DEV" "$PIVOT" || HOLD "cannot mount eMMC pivot — cannot revert, staying reachable"

# write-probe: busybox mount silently downgrades a write-protected device to
# an ro mount, and every protection below (counter, revert) needs writes. A
# failed probe does NOT hold a healthy boot hostage — the rootfs probe still
# runs — but it must be LOUD: the panic-loop breaker is gone in that state.
PIVOT_WRITABLE=1
if echo probe > "$PIVOT/boot/.jp5-wtest" 2>/dev/null && rm -f "$PIVOT/boot/.jp5-wtest" 2>/dev/null; then
    :
else
    PIVOT_WRITABLE=0
    klog "WARNING: eMMC pivot is NOT WRITABLE — attempt counter and auto-revert are DEAD; only this boot's rootfs probe still protects you"
fi

# --- 2. boot-attempt counter (breaks the mount-ok-then-panic loop) ---
n=$(cat "$PIVOT/$ATTEMPTS_REL" 2>/dev/null || echo 0)
n=$(echo "$n" | tr -cd '0-9' | sed 's/^0*//')   # digits only, no octal traps
[ -n "$n" ] || n=0
n=$((n+1))
if [ "$PIVOT_WRITABLE" = 1 ]; then
    echo "$n" > "$PIVOT/$ATTEMPTS_REL" || klog "WARNING: counter write failed — panic-loop protection degraded"
    sync
fi
klog "boot attempt $n/$MAX_ATTEMPTS (cleared only by jp5-boot-ok.service)"
if [ "$n" -gt "$MAX_ATTEMPTS" ]; then
    revert_and_reboot "$n boot attempts without a successful JP5 boot"
fi

# --- 3. probe the JP5 rootfs read-only BEFORE the real root mount ---
i=0
while [ "$i" -lt 30 ]; do [ -b "$ROOT_DEV" ] && break; sleep 1; i=$((i+1)); done
[ -b "$ROOT_DEV" ] || revert_and_reboot "JP5 root device $ROOT_DEV never appeared"

mkdir -p /mnt/jp5probe
if ! mount -o ro "$ROOT_DEV" /mnt/jp5probe 2>/dev/null; then
    revert_and_reboot "JP5 rootfs failed to mount (fs corrupt / wrong fstype)"
fi
# minimal sanity: a real rootfs has an init (symlink form counts — it resolves
# against the JP5 root after switch_root, not against this initramfs)
if [ ! -x /mnt/jp5probe/sbin/init ] && [ ! -L /mnt/jp5probe/sbin/init ] \
   && [ ! -x /mnt/jp5probe/lib/systemd/systemd ]; then
    umount /mnt/jp5probe 2>/dev/null
    revert_and_reboot "JP5 rootfs has no init — not a bootable rootfs"
fi
umount /mnt/jp5probe 2>/dev/null

# --- 4. proceed: leave the counter in place (jp5-boot-ok.service clears it) ---
umount "$PIVOT" 2>/dev/null || umount -l "$PIVOT" 2>/dev/null
klog "JP5 rootfs probe OK — proceeding to switch_root (attempt $n)"
exit 0
