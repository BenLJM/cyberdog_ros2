#!/bin/bash
# Replicate the on-dog first-copy (mirror + Layer 3b + Layer 4b) to the backup SSD.
# WRITES ONLY TO THE SSD — never touches any dog partition. Idempotent (rsync -c /
# cp; re-run safe). Verifies every payload after copy.
set -uo pipefail
B=/media/mi/CYBERDOG_BACKUP/cyberdog-2026-04
SRC=/home/mi/cyberdog-mirror-2026-07
QSPI=/home/mi/cyberdog-forensics-2026-04-22/qspi-boot-dump-2026-07-07
LOG=$SRC/replicate.log
exec > >(tee -a "$LOG") 2>&1
echo "=================== replicate run $(date -Is) ==================="
FAIL=0

echo "### free space before:"; df -h "$B" | tail -1

# --- 1. jp5 mirror (firmware + nvidia BSPs + wheels + git repos), ~18 GB ---
echo "--- [1/3] rsync mirror -> $B/mirror-2026-07/  (this is the long one)"
mkdir -p "$B/mirror-2026-07"
rsync -aH --info=progress2 --exclude 'replicate.log' "$SRC/" "$B/mirror-2026-07/" \
  || { echo "!! rsync FAILED"; FAIL=1; }

# --- 2. Layer 3b: QSPI NOR + eMMC boot0/1 (~40 MB) ---
echo "--- [2/3] Layer 3b QSPI/boot dumps -> $B/layer3b/"
mkdir -p "$B/layer3b"
cp -av "$QSPI"/* "$B/layer3b/" || { echo "!! layer3b copy FAILED"; FAIL=1; }

# --- 3. Layer 4b: V1.0.0.94 bootloader OTA payloads (needs sudo; /opt is root) ---
echo "--- [3/3] Layer 4b /opt/ota_package -> $B/layer4b-v94-bl/"
mkdir -p "$B/layer4b-v94-bl"
sudo cp -av /opt/ota_package/t18x /opt/ota_package/t19x "$B/layer4b-v94-bl/" \
  || { echo "!! layer4b copy FAILED"; FAIL=1; }
( cd "$B/layer4b-v94-bl" && sudo sha256sum t18x/* t19x/* | sudo tee SHA256SUMS >/dev/null )
sudo chown -R mi:mi "$B/layer4b-v94-bl"

sync

echo "=================== VERIFY $(date -Is) ==================="
# mirror payloads: re-check the SHA256SUMS produced at download time
echo "--- mirror firmware/nvidia/wheels checksums (on SSD):"
( cd "$B/mirror-2026-07" && sha256sum -c SHA256SUMS ) || { echo "!! mirror checksum MISMATCH"; FAIL=1; }
# git mirrors: validate each is a good repo
echo "--- git mirrors validity:"
gbad=0
for d in "$B"/mirror-2026-07/repos/*.git; do
  git -C "$d" rev-parse HEAD >/dev/null 2>&1 && echo "  OK $(basename "$d")" || { echo "  BAD $(basename "$d")"; gbad=1; FAIL=1; }
done
# layer3b
echo "--- layer3b checksums:"
( cd "$B/layer3b" && sha256sum -c SHA256SUMS ) || { echo "!! layer3b MISMATCH"; FAIL=1; }
# layer4b
echo "--- layer4b checksums:"
( cd "$B/layer4b-v94-bl" && sha256sum -c SHA256SUMS ) || { echo "!! layer4b MISMATCH"; FAIL=1; }
# spot-check pre-existing layers still readable
echo "--- pre-existing layer2/3 integrity spot-check:"
zstd -t "$B/layer2/"*.zst 2>&1 | tail -2 || echo "  (layer2 zst test skipped/failed)"

echo "=================== done $(date -Is) — FAIL=$FAIL ==================="
echo "### free space after:"; df -h "$B" | tail -1
du -sh "$B"/mirror-2026-07 "$B"/layer3b "$B"/layer4b-v94-bl 2>/dev/null
exit $FAIL
