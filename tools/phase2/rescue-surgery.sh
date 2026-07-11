#!/bin/bash
# Automated Phase-2 NVMe surgery. Runs INSIDE the rescue initramfs only.
# Every value below was measured live on 2026-07-11; every step verifies the
# world matches before writing. Any mismatch -> abort with nothing half-done
# (the only non-instant window is the resize2fs shrink itself).
#
#   --selftest : run the read-only gates on a LIVE JP4 system (expects the
#                "nothing from NVMe may be mounted" gate to FAIL there, and
#                geometry/fs/tool gates to PASS). No writes. Safe anywhere.
#
# Exit 0 = surgery complete + verified. Non-zero = aborted; log says where.
set -u

DISK=/dev/nvme0n1
P1=${DISK}p1
P2=${DISK}p2
P3=${DISK}p3

# measured 2026-07-11 (sgdisk -p / -i 1, dumpe2fs -h)
EXP_DISK_SECTORS=250069680
EXP_P1_START=40
EXP_P1_END=250066983
EXP_FS_BLOCKS=31258368
EXP_BLOCK_SIZE=4096
P1_GUID=0D799F10-BC04-4D32-AF66-771FD6147249

# targets (sector-exact; all multiples of the disk's 8-sector alignment)
NEW_P1_END=104859647          # p1 becomes 50.0 GiB
P2_START=104859648
P2_END=209717247              # p2 = exactly 50 GiB
P3_START=209717248            # p3 = rest (~19.2 GiB)
SHRINK_BLOCKS=12582912        # 48 GiB in 4K blocks (interim, before final grow)
FINAL_BLOCKS=13107451         # new p1 size is exactly this many 4K blocks

step() { echo "== [$(date '+%H:%M:%S' 2>/dev/null)] $*"; sync; }
fail() { echo "!! ABORT: $*"; sync; exit 1; }

# ---------------- gates (read-only) ----------------
gate_geometry() {
    local p
    p=$(sgdisk -p "$DISK" 2>/dev/null) || return 1
    echo "$p" | grep -q "^Disk $DISK: $EXP_DISK_SECTORS sectors" || { echo "disk size mismatch"; return 1; }
    [ "$(echo "$p" | awk '$1 ~ /^[0-9]+$/ {n++} END{print n}')" = 1 ] || { echo "expected exactly 1 partition"; return 1; }
    echo "$p" | awk '$1==1 {exit !($2=='"$EXP_P1_START"' && $3=='"$EXP_P1_END"')}' || { echo "p1 bounds mismatch"; return 1; }
    return 0
}
gate_fs() {
    local d
    d=$(dumpe2fs -h "$P1" 2>/dev/null) || return 1
    echo "$d" | grep -q "^Block count: *$EXP_FS_BLOCKS\$" || { echo "fs block count mismatch"; return 1; }
    echo "$d" | grep -q "^Block size: *$EXP_BLOCK_SIZE\$" || { echo "fs block size mismatch"; return 1; }
    return 0
}
gate_tools() {
    local t
    for t in sgdisk resize2fs e2fsck dumpe2fs mkfs.ext4 partprobe blkid; do
        command -v "$t" >/dev/null || { echo "missing tool $t"; return 1; }
    done
    return 0
}
gate_unmounted() { ! grep -q nvme /proc/mounts; }
gate_rescue_env() { grep -q 'cyberdog.rescue=1' /proc/cmdline; }

if [ "${1:-}" = --selftest ]; then
    echo "selftest on live system:"
    gate_tools    && echo "  tools    PASS" || echo "  tools    FAIL (BAD)"
    gate_geometry && echo "  geometry PASS" || echo "  geometry FAIL (BAD)"
    gate_fs       && echo "  fs       PASS" || echo "  fs       FAIL (BAD)"
    gate_unmounted && echo "  unmounted PASS (UNEXPECTED on live JP4!)" || echo "  unmounted FAIL (expected on live JP4)"
    gate_rescue_env && echo "  rescue-env PASS (unexpected on JP4)" || echo "  rescue-env FAIL (expected on JP4)"
    exit 0
fi

step "gates"
gate_rescue_env || fail "not in rescue environment"
gate_unmounted  || fail "something from the NVMe is mounted"
gate_tools      || fail "tool missing"
gate_geometry   || fail "disk geometry differs from measured baseline"
gate_fs         || fail "filesystem differs from measured baseline"
step "gates ALL PASS"

# ---------------- surgery ----------------
step "S1 e2fsck (pre)"
e2fsck -f -y "$P1"; rc=$?
[ "$rc" -le 2 ] || fail "pre-fsck rc=$rc"

step "S2 shrink filesystem to $SHRINK_BLOCKS blocks (48 GiB) — do NOT power off"
resize2fs "$P1" "$SHRINK_BLOCKS" || fail "resize2fs shrink failed"

step "S3 verify shrink"
dumpe2fs -h "$P1" 2>/dev/null | grep -q "^Block count: *$SHRINK_BLOCKS\$" \
    || fail "post-shrink block count wrong"

step "S4 shrink partition 1 (recreate 40..$NEW_P1_END, same GUID/type/name)"
sgdisk -a 8 -d 1 -n "1:$EXP_P1_START:$NEW_P1_END" -t 1:0700 -c 1:APP -u "1:$P1_GUID" "$DISK" \
    || fail "sgdisk p1 recreate failed"

step "S5 create p2 (JP5_ROOT) + p3 (DATA)"
sgdisk -a 8 -n "2:$P2_START:$P2_END" -t 2:8300 -c 2:JP5_ROOT "$DISK" || fail "sgdisk p2 failed"
sgdisk -a 8 -n "3:$P3_START:0"       -t 3:8300 -c 3:DATA     "$DISK" || fail "sgdisk p3 failed"

step "S6 verify partition table + reread"
p=$(sgdisk -p "$DISK")
echo "$p"
echo "$p" | awk '$1==1 {exit !($2=='"$EXP_P1_START"' && $3=='"$NEW_P1_END"')}' || fail "p1 verify failed"
echo "$p" | awk '$1==2 {exit !($2=='"$P2_START"' && $3=='"$P2_END"')}'         || fail "p2 verify failed"
echo "$p" | awk '$1==3 {exit !($2=='"$P3_START"')}'                            || fail "p3 verify failed"
partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" || true
for i in $(seq 20); do [ -b "$P2" ] && [ -b "$P3" ] && break; sleep 1; done
[ -b "$P2" ] && [ -b "$P3" ] || fail "p2/p3 device nodes never appeared"

step "S7 grow p1 filesystem to fill partition + fsck"
resize2fs "$P1" || fail "resize2fs grow failed"
dumpe2fs -h "$P1" 2>/dev/null | grep -q "^Block count: *$FINAL_BLOCKS\$" \
    || fail "post-grow block count != $FINAL_BLOCKS"
e2fsck -f -y "$P1"; rc=$?
[ "$rc" -le 1 ] || fail "post-grow fsck rc=$rc"

step "S8 mkfs p2 + p3"
mkfs.ext4 -q -F -L JP5_ROOT "$P2" || fail "mkfs p2 failed"
mkfs.ext4 -q -F -L DATA     "$P3" || fail "mkfs p3 failed"

step "S9 read-only sanity mount of p1"
mkdir -p /tmp/p1check
mount -o ro "$P1" /tmp/p1check || fail "p1 ro-mount failed"
grep -q '18.04' /tmp/p1check/etc/os-release || { umount /tmp/p1check; fail "os-release check failed"; }
umount /tmp/p1check

step "S10 final state"
blkid "$P1" "$P2" "$P3"
sgdisk -p "$DISK"
step "SURGERY COMPLETE"
exit 0
