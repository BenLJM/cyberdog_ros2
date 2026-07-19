#!/bin/bash
# ONE-BUTTON Phase-2 surgery launcher. Run as:  sudo bash ~/phase2/arm-and-go.sh
#
# TWO-STAGE since 2026-07-12: cboot's ramdisk buffer silently rejected the
# 13 MB monolithic initrd (fell back to stock /boot/initrd -> JP4 booted with
# the rescue APPEND, surgery never started). Now cboot loads a ~2 MB stage-1
# loader; the full rescue system lives on the eMMC pivot as a sha256-gated
# bundle that stage-1 unpacks into RAM and switch_roots into.
#
# Does, in order, stopping on any failure:
#   1. rebuild stage-1 loader + stage-2 bundle (surgery chain inside)
#   2. verify both offline (syntax of every script, sshd -t in chroot,
#      surgery parameters present, autorun wired into inittab, stage-1
#      embedded sha == bundle sha, stage-1 within the stock size envelope,
#      bundle unpacks with the SAME busybox binary stage-1 will use)
#   3. install both to the eMMC boot pivot (sha256-verified after copy)
#   4. arm the one-shot surgery flag + set DEFAULT to rescue
#   5. 30-second countdown (Ctrl-C aborts and reverts cleanly), then reboot
#
# What happens after the reboot, fully automatic:
#   stage-1 boots from RAM -> verifies + unpacks bundle -> full rescue ->
#   gates re-check everything -> flag consumed -> fsck -> shrink fs (48 GiB)
#   -> shrink p1 (50 GiB) -> create p2/p3 -> grow fs -> fsck -> mkfs p2/p3
#   -> sanity mount -> DEFAULT back to primary -> reboot into normal JP4.
#   Expect 10-25 min offline. Any failed check: dog STAYS in rescue with sshd
#   up (Wi-Fi ~2-3 min after boot at the usual IP, or USB 192.168.55.1);
#   log: /boot/phase2-surgery.log on mmcblk0p1.
set -euo pipefail
PH2=/home/mi/phase2
MNT=/mnt/emmc-app
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
[ -x /usr/local/sbin/cyberdog-boot-switch ] || die "cyberdog-boot-switch not installed"

echo "=== 1/5 rebuild stage-1 loader + stage-2 bundle"
bash "$PH2/build-rescue-initrd.sh"
[ -f "$PH2/initrd-rescue" ]         || die "builder produced no stage-1"
[ -f "$PH2/rescue-bundle.cpio.gz" ] || die "builder produced no bundle"

echo "=== 2/5 offline verification"
mountpoint -q "$MNT" || { mkdir -p "$MNT"; mount /dev/mmcblk0p1 "$MNT"; }
V=$(mktemp -d)
mkdir "$V/bundle" "$V/s1"
# unpack BOTH with the same busybox binary (zcat AND cpio) stage-1 will use at boot
( cd "$V/bundle" && /bin/busybox zcat "$PH2/rescue-bundle.cpio.gz" | /bin/busybox cpio -idm ) \
    || die "bundle failed to unpack with the boot-time busybox"
( cd "$V/s1"     && /bin/busybox zcat "$PH2/initrd-rescue"         | /bin/busybox cpio -idm ) \
    || die "stage-1 failed to unpack with the boot-time busybox"

# --- stage-2 bundle: the full rescue system ---
for f in init etc/rc.rescue sbin/rescue-surgery sbin/rescue-autorun \
         sbin/rescue-boot-switch sbin/back-to-jp4; do
    bash -n "$V/bundle/$f" || die "syntax error in bundle $f"
done
chroot "$V/bundle" /usr/sbin/sshd -t -f /etc/ssh/sshd_config || die "sshd config check failed"
grep -q '^::once:/sbin/rescue-autorun$' "$V/bundle/etc/inittab" || die "autorun not in inittab"
grep -q 'NEW_P1_END=104859647' "$V/bundle/sbin/rescue-surgery" || die "surgery params missing"
grep -q 'SHRINK_BLOCKS=12582912' "$V/bundle/sbin/rescue-surgery" || die "surgery params missing"
grep -q 'P1_GUID=0D799F10-BC04-4D32-AF66-771FD6147249' "$V/bundle/sbin/rescue-surgery" || die "p1 GUID missing"
[ -x "$V/bundle/sbin/wpa_supplicant" ] || die "wpa_supplicant missing from bundle"
grep -q 'network=' "$V/bundle/etc/wpa_supplicant.conf" || die "no Wi-Fi credentials in bundle"
[ -x "$V/bundle/etc/udhcpc.script" ] || die "udhcpc script missing"
# the exact gate_tools check rescue-surgery will run, resolved INSIDE the bundle
# (2026-07-16 review: mkfs.ext4 was missing and only the armed boot would have noticed)
chroot "$V/bundle" /bin/bash -c true || die "bundle /bin/bash missing or broken"
for t in parted sgdisk resize2fs e2fsck dumpe2fs mkfs.ext4 tune2fs partprobe blkid; do
    chroot "$V/bundle" /bin/bash -c "PATH=/bin:/sbin:/usr/bin:/usr/sbin:/bb command -v $t" >/dev/null \
        || die "bundle missing surgery tool $t"
done

# --- stage-1 loader ---
/bin/busybox ash -n "$V/s1/init" || die "stage-1 init syntax error"
[ -x "$V/s1/bin/busybox" ] || die "stage-1 busybox missing"
[ -x "$V/s1/init" ] || die "stage-1 init not executable"
/bin/busybox --list > "$V/bb.applets"   # file first: pipefail+grep -q races on SIGPIPE
for a in sh mount umount switch_root sha256sum cpio zcat sleep grep mv date; do
    grep -qx "$a" "$V/bb.applets" || die "busybox lacks applet $a"
done
BSHA=$(sha256sum "$PH2/rescue-bundle.cpio.gz" | cut -d' ' -f1)
grep -q "^$BSHA  /mnt/pivot/boot/rescue-bundle.cpio.gz\$" "$V/s1/etc/bundle.sha256" \
    || die "stage-1 embedded sha != bundle sha"
# exercise the REAL boot-time check: busybox sha256sum -c must work on this box
printf '%s  %s\n' "$BSHA" "$PH2/rescue-bundle.cpio.gz" > "$V/chk"
/bin/busybox sha256sum -c "$V/chk" >/dev/null || die "busybox sha256sum -c unusable"

# --- size gates: stage-1 must sit strictly inside the PROVEN cboot envelope ---
STOCK_PACKED=$(stat -c%s "$MNT/boot/initrd")
STOCK_RAW=$(zcat "$MNT/boot/initrd" | wc -c)
S1_PACKED=$(stat -c%s "$PH2/initrd-rescue")
S1_RAW=$(zcat "$PH2/initrd-rescue" | wc -c)
[ "$S1_PACKED" -lt "$STOCK_PACKED" ] || die "stage-1 packed $S1_PACKED >= stock $STOCK_PACKED"
[ "$S1_RAW"    -lt "$STOCK_RAW"    ] || die "stage-1 raw $S1_RAW >= stock raw $STOCK_RAW"
rm -rf "$V"
echo "    verification OK (stage-1 ${S1_PACKED}B/${S1_RAW}B vs stock ${STOCK_PACKED}B/${STOCK_RAW}B; Wi-Fi creds in bundle)"

if [ "${1:-}" = "--verify-only" ]; then
    echo "=== --verify-only: stopping before install/arm. Nothing touched on the pivot."
    exit 0
fi

echo "=== 3/5 install both artifacts to boot pivot"
grep -q "^LABEL rescue$" "$MNT/boot/extlinux/extlinux.conf" || die "LABEL rescue missing"
for art in initrd-rescue rescue-bundle.cpio.gz; do
    cp "$PH2/$art" "$MNT/boot/$art.tmp"
    sync
    mv "$MNT/boot/$art.tmp" "$MNT/boot/$art"
    sync
    want=$(sha256sum "$PH2/$art" | cut -d' ' -f1)
    got=$(sha256sum "$MNT/boot/$art" | cut -d' ' -f1)
    [ "$want" = "$got" ] || die "sha256 mismatch after copying $art"
    chmod 600 "$MNT/boot/$art"    # bundle embeds Wi-Fi PSK + host keys
    echo "    installed $art ($got)"
done

echo "=== 4/5 arm one-shot surgery + DEFAULT rescue"
# disarm trap covers the ENTIRE arm window (2026-07-16 review), stays until death
trap 'echo; echo "aborted — disarming"; rm -f "$MNT/boot/phase2-autorun-surgery"; /usr/local/sbin/cyberdog-boot-switch primary; sync; exit 1' INT
rm -f "$MNT/boot/phase2-surgery.SUCCESS" "$MNT/boot/phase2-surgery.FAILED" \
      "$MNT/boot/phase2-surgery.STARTED" "$MNT/boot/phase2-autorun-surgery.stale" \
      "$MNT/boot/phase2-stage1.log"
# DEFAULT first, flag LAST: a crash in between leaves an unarmed rescue boot
# (manual rescue, sshd up) — strictly safer than a live flag on DEFAULT=primary
/usr/local/sbin/cyberdog-boot-switch rescue || die "boot-switch failed — nothing armed"
touch "$MNT/boot/phase2-autorun-surgery"
sync

echo "=== 5/5 rebooting in 30 s — Ctrl-C NOW to abort"
for i in $(seq 30 -1 1); do printf "\r  reboot in %2d s " "$i"; sleep 1; done
echo
echo "Dog goes offline now. Back on Wi-Fi in 10-25 min if all green."
echo "Not back after 30 min? Laptop on the USB cable, static 192.168.55.100/24,"
echo "ssh root@192.168.55.1, read /boot/phase2-surgery.log (mount /dev/mmcblk0p1)."
sync
reboot
