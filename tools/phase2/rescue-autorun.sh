#!/bin/bash
# Runs once per rescue boot (inittab ::once). If the arm-flag file exists on
# the boot pivot, consumes it FIRST (so a power-cycle never re-runs surgery on
# a half-done disk), then runs the surgery. Success -> flip DEFAULT back to
# primary + reboot into JP4. Failure -> stay in rescue with sshd up for manual
# access; log + FAILED marker on the pivot say exactly where it stopped.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/bb
sleep 3

M=/mnt/pivot
mkdir -p "$M"
mount /dev/mmcblk0p1 "$M" 2>/dev/null || exit 0
FLAG="$M/boot/phase2-autorun-surgery"
if [ ! -f "$FLAG" ]; then
    umount "$M"
    exit 0          # manual rescue session — do nothing
fi

LOG="$M/boot/phase2-surgery.log"
exec >> "$LOG" 2>&1
echo "===================================================================="
echo "rescue-autorun: armed boot detected ($(date 2>/dev/null))"
echo "consuming arm flag (one attempt only); STARTED marker written first so"
echo "stage-1 can distinguish mid-surgery power loss (HOLD) from never-armed (JP4)"
# VERIFIED transaction: refuse surgery if the pivot won't take our markers —
# proceeding without STARTED (or with a live flag) breaks stage-1's matrix.
touch "$M/boot/phase2-surgery.STARTED" && sync && [ -f "$M/boot/phase2-surgery.STARTED" ] || {
    echo "rescue-autorun: cannot write STARTED marker — refusing surgery" | tee /dev/kmsg
    exit 1     # flag left intact; dog stays in rescue with sshd for diagnosis
}
rm -f "$FLAG"
sync
[ ! -f "$FLAG" ] || {
    echo "rescue-autorun: cannot consume arm flag (pivot read-only?) — refusing surgery" | tee /dev/kmsg
    exit 1
}

echo "rescue-autorun: starting surgery (also logged here)" > /dev/kmsg
/sbin/rescue-surgery
rc=$?

if [ "$rc" = 0 ]; then
    echo "rescue-autorun: SUCCESS — flipping DEFAULT to primary and rebooting"
    c="$M/boot/extlinux/extlinux.conf"
    sed 's/^DEFAULT .*/DEFAULT primary/' "$c" > "$c.tmp"
    if grep -q '^DEFAULT primary$' "$c.tmp"; then
        mv "$c.tmp" "$c"
        touch "$M/boot/phase2-surgery.SUCCESS"
    else
        rm -f "$c.tmp"
        echo "rescue-autorun: DEFAULT flip verify failed — staying in rescue"
        touch "$M/boot/phase2-surgery.FAILED"
        sync; umount "$M"
        exit 1
    fi
    sync
    exec > /dev/kmsg 2>&1      # release the log fd so the pivot can unmount
    umount "$M"
    echo "rescue-autorun: rebooting to JP4 now"
    sleep 2
    exec /bb/reboot -f
else
    echo "rescue-autorun: surgery FAILED (rc=$rc) — staying in rescue for manual access"
    echo "  ssh root@192.168.55.1 (laptop static 192.168.55.100/24), or ttyACM serial"
    echo "  log: this file; escape hatch: back-to-jp4 (only after reading the log!)"
    touch "$M/boot/phase2-surgery.FAILED"
    sync
    # deliberately leave $M mounted for the manual session
    echo "rescue-autorun: surgery FAILED — ssh root@192.168.55.1, read /boot/phase2-surgery.log on mmcblk0p1" > /dev/kmsg
    exit 1
fi
