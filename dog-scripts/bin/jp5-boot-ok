#!/bin/bash
# jp5-boot-ok — clear the JP5 boot-attempt counter on the eMMC boot pivot.
# Installed into the JP5 rootfs as /usr/local/sbin/jp5-boot-ok and run by
# jp5-boot-ok.service once multi-user.target is reached. Until this runs, every
# initrd pass increments /boot/jp5-boot-attempts; after MAX_ATTEMPTS (3) the
# initrd guard reverts DEFAULT to JP4 (tools/phase3/jp5-autorevert-hook.sh).
#
# Failure semantics (INTENTIONAL, 2026-07-19 review): if this persistently
# fails on 3 consecutive boots with no success in between, a healthy JP5 gets
# reverted to JP4 — that is the safe direction ("can't prove the boot is good"
# = treat as not good). The in-script retries below absorb transient wobbles;
# a persistent failure is loud in the journal (unit shows failed).
set -euo pipefail
M=/run/jp5-bootpivot
mkdir -p "$M"
own_mount=0
cleanup() { [ "$own_mount" = 1 ] && umount "$M" 2>/dev/null || true; }
trap cleanup EXIT

if ! grep -q "^/dev/mmcblk0p1 $M " /proc/mounts; then
    ok=0
    for i in 1 2 3 4 5 6; do
        if mount /dev/mmcblk0p1 "$M"; then ok=1; own_mount=1; break; fi
        logger -t jp5-boot-ok "mount attempt $i/6 failed — retrying in 10s"
        sleep 10
    done
    if [ "$ok" != 1 ]; then
        logger -p err -t jp5-boot-ok "FAILED to mount the eMMC pivot after 6 tries — boot-attempt counter NOT cleared; 3 such boots in a row will auto-revert to JP4"
        exit 1
    fi
fi

if [ -f "$M/boot/jp5-boot-attempts" ]; then
    n=$(cat "$M/boot/jp5-boot-attempts" 2>/dev/null || echo '?')
    rm -f "$M/boot/jp5-boot-attempts"
    sync
    logger -t jp5-boot-ok "JP5 boot successful — cleared boot-attempt counter (was $n)"
else
    logger -t jp5-boot-ok "JP5 boot successful — no counter present"
fi
# the counter is cleared — that IS this unit's success; umount happens in the
# EXIT trap and must not flip the verdict
exit 0
