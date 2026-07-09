#!/bin/bash
# Rescue drill (dog-native, arm64) — prove the Layer 2 rootfs backup restores.
# NON-DESTRUCTIVE: works only inside a loopback file + a temp mountpoint. Touches
# NO real partition. Verifies by reading files (no chroot exec) — safer than the
# x86/qemu runbook §5 flow and just as conclusive for "does the tar restore whole".
set -uo pipefail

B=/media/mi/CYBERDOG_BACKUP/cyberdog-2026-04
TAR=$B/layer2/rootfs-nvme.tar.zst
IMG=${1:-/home/mi/rescue-drill/rescue-drill.img}   # loopback on NVMe (fast; keeps SSD free)
MNT=/mnt/rescue-drill
OUT=$B/RESCUE_DRILL_RESULT.txt
SZ=22G

cleanup() {
  mountpoint -q "$MNT" && sudo umount "$MNT"
  [ -n "${LOOP:-}" ] && sudo losetup -d "$LOOP" 2>/dev/null
  sudo rmdir "$MNT" 2>/dev/null
  [ -f "$IMG" ] && rm -f "$IMG"
}
trap cleanup EXIT

echo "=== rescue drill (native) $(date -Is) ===" | tee "$OUT"
[ -f "$TAR" ] || { echo "!! Layer 2 tar not found: $TAR" | tee -a "$OUT"; exit 2; }
echo "source tar: $TAR ($(du -h "$TAR" | cut -f1))" | tee -a "$OUT"

echo "--- create + format ${SZ} loopback: $IMG"
truncate -s "$SZ" "$IMG"
sudo mkfs.ext4 -q -F -L RESCUE_TEST "$IMG"
sudo mkdir -p "$MNT"
LOOP=$(sudo losetup --find --show "$IMG")
sudo mount "$LOOP" "$MNT"
echo "mounted $LOOP -> $MNT"

echo "--- restore Layer 2 (zstd -T0 -d | tar x). Takes a few minutes..."
t0=$SECONDS
sudo tar --xattrs --acls --numeric-owner -I 'zstd -T0 -d' -xf "$TAR" -C "$MNT"
echo "restore wall time: $((SECONDS - t0)) s" | tee -a "$OUT"

echo "=== VERIFY (file-level, no chroot) ===" | tee -a "$OUT"
{
  echo "--- /etc/os-release:"
  grep -E 'PRETTY_NAME|VERSION_ID' "$MNT/etc/os-release" 2>/dev/null || echo "  MISSING os-release"
  echo "--- athena-version (from dpkg status):"
  awk '/^Package: athena-version/{p=1} p&&/^Version:/{print "  "$0; p=0}' "$MNT/var/lib/dpkg/status" 2>/dev/null || echo "  MISSING"
  echo "--- athena packages installed (count):"
  grep -c '^Package: athena' "$MNT/var/lib/dpkg/status" 2>/dev/null
  echo "--- /opt/ros2/cyberdog present?"
  ls "$MNT/opt/ros2/cyberdog/" 2>/dev/null | head -5 || echo "  MISSING"
  echo "--- keystone closed lib restored?"
  ls -la "$MNT"/opt/ros2/cyberdog/lib/libathena_utils_core.so 2>/dev/null || echo "  MISSING keystone"
  echo "--- total files restored:"
  find "$MNT" -xdev | wc -l
} | tee -a "$OUT"

# Pass gate
OK=1
grep -q '18.04' "$MNT/etc/os-release" 2>/dev/null || { echo "FAIL: os-release not 18.04" | tee -a "$OUT"; OK=0; }
grep -q '^Package: athena-version' "$MNT/var/lib/dpkg/status" 2>/dev/null || { echo "FAIL: athena-version absent" | tee -a "$OUT"; OK=0; }
[ -e "$MNT/opt/ros2/cyberdog" ] || { echo "FAIL: /opt/ros2/cyberdog absent" | tee -a "$OUT"; OK=0; }
n=$(find "$MNT" -xdev 2>/dev/null | wc -l); [ "$n" -ge 300000 ] || { echo "WARN: only $n files (<300k)" | tee -a "$OUT"; }

echo "=== RESULT: $([ $OK = 1 ] && echo PASS || echo FAIL) $(date -Is) ===" | tee -a "$OUT"
echo "(result saved to $OUT; loopback cleaned up automatically)"
exit $((1 - OK))
