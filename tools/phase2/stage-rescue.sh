#!/bin/bash
# Phase 2 §3.2–3.3 — stage the rescue boot path onto eMMC APP p1. ADDITIVE ONLY:
#   + /boot/initrd-rescue                     (new file)
#   + LABEL rescue appended to extlinux.conf  (DEFAULT stays primary)
#   + canonical saved copies extlinux.conf.{stock,jp4,rescue}-saved
#   + cyberdog-boot-switch -> /usr/local/sbin
# Gate: live extlinux.conf must be byte-identical to the Phase 0.5 pristine
# backup, i.e. the dog is in known-stock state. Every edit is tmp+mv atomic.
set -euo pipefail

PH2=/home/mi/phase2
MNT=/mnt/emmc-app
PRISTINE=/home/mi/phase0.5/backups/extlinux.conf.emmc.orig

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
[ -f "$PH2/initrd-rescue" ] || die "build initrd-rescue first"

mountpoint -q "$MNT" || { mkdir -p "$MNT"; mount /dev/mmcblk0p1 "$MNT"; }
CONF="$MNT/boot/extlinux/extlinux.conf"

# ---- gate: known-stock starting point ----
cmp -s "$CONF" "$PRISTINE" \
    || die "live extlinux.conf differs from Phase 0.5 pristine backup — resolve first"
grep -q "^DEFAULT primary$" "$CONF" || die "DEFAULT is not primary"

mkdir -p "$PH2/backups"
cp -a "$CONF" "$PH2/backups/extlinux.conf.pre-phase2"

# ---- install initrd-rescue ----
cp "$PH2/initrd-rescue" "$MNT/boot/initrd-rescue.tmp"
sync
mv "$MNT/boot/initrd-rescue.tmp" "$MNT/boot/initrd-rescue"
sync
want=$(cut -d' ' -f1 "$PH2/initrd-rescue.sha256")
got=$(sha256sum "$MNT/boot/initrd-rescue" | cut -d' ' -f1)
[ "$want" = "$got" ] || die "initrd-rescue sha256 mismatch after copy"

# ---- append LABEL rescue (DEFAULT untouched) ----
{
    cat "$CONF"
    cat <<'EOF'

LABEL rescue
	MENU LABEL RESCUE (RAM, JP4 kernel, no NVMe mount)
	INITRD /boot/initrd-rescue
	APPEND ${cbootargs} rw rootwait console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0 cyberdog.rescue=1
EOF
} > "$CONF.tmp"
# verify: original content is an exact prefix, rescue label present, DEFAULT still primary
head -c "$(stat -c %s "$CONF")" "$CONF.tmp" | cmp -s - "$CONF" || { rm -f "$CONF.tmp"; die "prefix check failed"; }
grep -q "^LABEL rescue$" "$CONF.tmp" || { rm -f "$CONF.tmp"; die "rescue label missing"; }
grep -q "^DEFAULT primary$" "$CONF.tmp" || { rm -f "$CONF.tmp"; die "DEFAULT changed"; }
mv "$CONF.tmp" "$CONF"
sync

# ---- canonical saved copies ----
cp -a "$PRISTINE" "$MNT/boot/extlinux/extlinux.conf.stock-saved"
cp -a "$CONF" "$MNT/boot/extlinux/extlinux.conf.jp4-saved"          # rescue label, DEFAULT primary
sed 's/^DEFAULT .*/DEFAULT rescue/' "$CONF" > "$MNT/boot/extlinux/extlinux.conf.rescue-saved"
sync

# ---- boot-switch tool ----
install -m 755 "$PH2/cyberdog-boot-switch" /usr/local/sbin/cyberdog-boot-switch

echo "== staged. Current state:"
/usr/local/sbin/cyberdog-boot-switch status
echo "== files on eMMC APP p1:"
ls -la "$MNT/boot/initrd-rescue" "$MNT/boot/extlinux/"
echo
echo "NEXT (needs owner, evening with next day free — PHASE2_RUNBOOK.md §4):"
echo "  sudo cyberdog-boot-switch rescue && sudo reboot"
echo "  then from laptop: ssh root@192.168.55.1 (host static 192.168.55.100/24)"
echo "  in rescue: back-to-jp4   # returns to JP4"
