#!/bin/bash
# Phase 2 §4.3 prep — stage the dual-kernel LINUX-from-file proof. ADDITIVE:
#   + /boot-jp5/{Image,tegra194-mi-k91.dtb} on eMMC APP p1 (byte-copies of JP4's)
#   + LABEL jp5 (LINUX+FDT from files, root=nvme0n1p1 i.e. still the JP4 rootfs)
#   + regenerated saved copies including the new label
# DEFAULT stays primary. On rehearsal night 2:
#   sudo cyberdog-boot-switch jp5 && sudo reboot; landing kernel must equal JP4's
#   -> directly proves LINUX-from-file (FDT+INITRD already proven Phase 0.5).
set -euo pipefail

MNT=/mnt/emmc-app
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
mountpoint -q "$MNT" || { mkdir -p "$MNT"; mount /dev/mmcblk0p1 "$MNT"; }
CONF="$MNT/boot/extlinux/extlinux.conf"

grep -q "^LABEL rescue$" "$CONF" || die "run stage-rescue.sh first"
grep -q "^DEFAULT primary$" "$CONF" || die "DEFAULT is not primary — resolve first"
grep -q "^LABEL jp5$" "$CONF" && die "LABEL jp5 already present"

mkdir -p "$MNT/boot-jp5"
for f in Image tegra194-mi-k91.dtb; do
    cp "$MNT/boot/$f" "$MNT/boot-jp5/$f.tmp"
    sync
    mv "$MNT/boot-jp5/$f.tmp" "$MNT/boot-jp5/$f"
    cmp -s "$MNT/boot/$f" "$MNT/boot-jp5/$f" || die "$f copy mismatch"
done
sync

{
    cat "$CONF"
    cat <<'EOF'

LABEL jp5
	MENU LABEL jp5 slot (NOW: LINUX/FDT-from-file proof with JP4 kernel copy)
	LINUX /boot-jp5/Image
	FDT /boot-jp5/tegra194-mi-k91.dtb
	INITRD /boot/initrd
	APPEND ${cbootargs} quiet root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0
EOF
} > "$CONF.tmp"
head -c "$(stat -c %s "$CONF")" "$CONF.tmp" | cmp -s - "$CONF" || { rm -f "$CONF.tmp"; die "prefix check failed"; }
grep -q "^LABEL jp5$" "$CONF.tmp" || { rm -f "$CONF.tmp"; die "jp5 label missing"; }
grep -q "^DEFAULT primary$" "$CONF.tmp" || { rm -f "$CONF.tmp"; die "DEFAULT changed"; }
mv "$CONF.tmp" "$CONF"
sync

# regenerate canonical saved copies from the new live content
cp -a "$CONF" "$MNT/boot/extlinux/extlinux.conf.jp4-saved"
sed 's/^DEFAULT .*/DEFAULT rescue/' "$CONF" > "$MNT/boot/extlinux/extlinux.conf.rescue-saved"
sed 's/^DEFAULT .*/DEFAULT jp5/'    "$CONF" > "$MNT/boot/extlinux/extlinux.conf.jp5-saved"
sync

echo "== staged. Labels now:"
grep '^LABEL \|^DEFAULT ' "$CONF"
echo "== /boot-jp5:"
ls -la "$MNT/boot-jp5/"
df -h "$MNT" | tail -1
echo
echo "Rehearsal night 2 (owner):  sudo cyberdog-boot-switch jp5 && sudo reboot"
echo "  success = dog boots normally, uname -a identical to JP4 baseline"
echo "  then:    sudo cyberdog-boot-switch primary && sudo reboot"
