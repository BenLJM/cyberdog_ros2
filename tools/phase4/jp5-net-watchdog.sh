#!/bin/bash
# jp5-net-watchdog — headless first-boot safety net for JP5 (2026-07-20).
# Installed into the JP5 rootfs; run ONCE, some minutes after boot, by the timer.
# Covers the one stranding state the initrd boot-guard cannot see: JP5 healthy
# (counter cleared at multi-user) but NO network reachable (the flaky internal
# USB Wi-Fi never came up) AND nobody logged in.
#
#   healthy (a default route exists, or someone is on a pts) -> clear strikes, exit
#   else -> strike++ on the eMMC pivot:
#     strikes < N   -> reboot (a fresh boot; also a fresh Wi-Fi enumeration try)
#     strikes >= N  -> restore extlinux.conf from jp4-saved (verified) -> next boot = JP4
#
# LIMITATION (learned 2026-07-20): the reboots are WARM. A wedged RTL8821CU
# often needs a COLD power-cycle to re-enumerate, which a warm reboot does not
# provide — so this net mainly guarantees "a headless dog eventually falls back
# to JP4", it does NOT reliably recover Wi-Fi. Keep the timer generous so a
# genuinely-slow-but-fine boot is not cut short.
set -u
M=/run/jp5-netwd
S=boot/jp5-net-strikes
MAX=3
log(){ logger -t jp5-net-watchdog "$*"; }

if who | grep -q pts || ip route | grep -q '^default'; then
    mkdir -p "$M"
    if mount /dev/mmcblk0p1 "$M" 2>/dev/null; then rm -f "$M/$S"; sync; umount "$M"; fi
    log "healthy (default route or active session) — strikes cleared"
    exit 0
fi

mkdir -p "$M"
mount /dev/mmcblk0p1 "$M" || { log "cannot mount eMMC pivot — no action, staying on JP5"; exit 1; }
n=$(cat "$M/$S" 2>/dev/null || echo 0); n=$(echo "$n" | tr -cd '0-9'); n=$(( ${n:-0} + 1 ))
echo "$n" > "$M/$S"; sync
log "no network, no session — strike $n/$MAX"
if [ "$n" -ge "$MAX" ]; then
    E="$M/boot/extlinux"
    if grep -q '^DEFAULT' "$E/extlinux.conf.jp4-saved" 2>/dev/null \
       && cp "$E/extlinux.conf.jp4-saved" "$E/extlinux.conf.tmp" && sync \
       && mv "$E/extlinux.conf.tmp" "$E/extlinux.conf" && sync \
       && cmp -s "$E/extlinux.conf.jp4-saved" "$E/extlinux.conf"; then
        mv "$M/$S" "$M/$S.reverted" 2>/dev/null
        log "$MAX strikes — REVERTED to JP4"
    else
        log "revert write FAILED — staying on JP5"
    fi
fi
sync; umount "$M" 2>/dev/null
log "rebooting"
systemctl reboot
