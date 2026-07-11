#!/bin/bash
# ONE-BUTTON Phase-2 surgery launcher. Run as:  sudo bash ~/phase2/arm-and-go.sh
#
# Does, in order, stopping on any failure:
#   1. rebuild the rescue initrd (now containing the gated auto-surgery)
#   2. verify it offline (syntax of every script, sshd -t in chroot,
#      surgery parameters present, autorun wired into inittab)
#   3. install it to the eMMC boot pivot (sha256-verified after copy)
#   4. arm the one-shot surgery flag + set DEFAULT to rescue
#   5. 30-second countdown (Ctrl-C aborts and reverts cleanly), then reboot
#
# What happens after the reboot, fully automatic:
#   rescue boots from RAM -> gates re-check everything -> flag consumed ->
#   fsck -> shrink fs (48 GiB) -> shrink p1 (50 GiB) -> create p2/p3 ->
#   grow fs -> fsck -> mkfs p2/p3 -> sanity mount -> DEFAULT back to primary
#   -> reboot into normal JP4 with the new layout. Expect 10-25 min offline.
#   Any failed check: dog STAYS in rescue, reachable at ssh root@192.168.55.1
#   (laptop static 192.168.55.100/24); log: /boot/phase2-surgery.log on mmcblk0p1.
set -euo pipefail
PH2=/home/mi/phase2
MNT=/mnt/emmc-app
die() { echo "ABORT: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"

echo "=== 1/5 rebuild initrd (with auto-surgery inside)"
bash "$PH2/build-rescue-initrd.sh"

echo "=== 2/5 offline verification"
V=$(mktemp -d)
( cd "$V" && zcat "$PH2/initrd-rescue" | cpio -idm --quiet )
for f in init etc/rc.rescue sbin/rescue-surgery sbin/rescue-autorun \
         sbin/rescue-boot-switch sbin/back-to-jp4; do
    bash -n "$V/$f" || die "syntax error in $f"
done
chroot "$V" /usr/sbin/sshd -t -f /etc/ssh/sshd_config || die "sshd config check failed"
grep -q '^::once:/sbin/rescue-autorun$' "$V/etc/inittab" || die "autorun not in inittab"
grep -q 'NEW_P1_END=104859647' "$V/sbin/rescue-surgery" || die "surgery params missing"
grep -q 'SHRINK_BLOCKS=12582912' "$V/sbin/rescue-surgery" || die "surgery params missing"
grep -q 'P1_GUID=0D799F10-BC04-4D32-AF66-771FD6147249' "$V/sbin/rescue-surgery" || die "p1 GUID missing"
rm -rf "$V"
echo "    verification OK"

echo "=== 3/5 install to boot pivot"
mountpoint -q "$MNT" || { mkdir -p "$MNT"; mount /dev/mmcblk0p1 "$MNT"; }
grep -q "^LABEL rescue$" "$MNT/boot/extlinux/extlinux.conf" || die "LABEL rescue missing"
cp "$PH2/initrd-rescue" "$MNT/boot/initrd-rescue.tmp"
sync
mv "$MNT/boot/initrd-rescue.tmp" "$MNT/boot/initrd-rescue"
sync
want=$(sha256sum "$PH2/initrd-rescue" | cut -d' ' -f1)
got=$(sha256sum "$MNT/boot/initrd-rescue" | cut -d' ' -f1)
[ "$want" = "$got" ] || die "sha256 mismatch after copy"
echo "    installed ($got)"

echo "=== 4/5 arm one-shot surgery + DEFAULT rescue"
rm -f "$MNT/boot/phase2-surgery.SUCCESS" "$MNT/boot/phase2-surgery.FAILED"
touch "$MNT/boot/phase2-autorun-surgery"
sync
/usr/local/sbin/cyberdog-boot-switch rescue

echo "=== 5/5 rebooting in 30 s — Ctrl-C NOW to abort"
trap 'echo; echo "aborted — disarming"; rm -f "$MNT/boot/phase2-autorun-surgery"; /usr/local/sbin/cyberdog-boot-switch primary; sync; exit 1' INT
for i in $(seq 30 -1 1); do printf "\r  reboot in %2d s " "$i"; sleep 1; done
trap - INT
echo
echo "Dog goes offline now. Back on Wi-Fi in 10-25 min if all green."
echo "Not back after 30 min? Laptop on the USB cable, static 192.168.55.100/24,"
echo "ssh root@192.168.55.1, read /boot/phase2-surgery.log (mount /dev/mmcblk0p1)."
sync
reboot
