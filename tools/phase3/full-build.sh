#!/bin/bash
# CyberDog JP5 kernel build (L4T r35.6.4 / 5.10.216) — runs INSIDE the
# cyberdog-kbuild container (native arm64), tree mounted at /work.
# MUST build to a native path (O=/tmp/kb), never the /work virtiofs mount
# (nvidia's in-tree `sed -i` codegen fails there).
#
# 2026-07-19 retrospective fixes (docs/RETROSPECTIVE-2026-07-19.md §八 A1):
#   - LOCALVERSION=-tegra → KREL matches stock 5.10.216-tegra (plan §12 gate)
#   - set -euo pipefail + explicit rc checks: a failed compile can no longer
#     slide through `| tail` and package stale artifacts from a previous run
#   - /work/out/final is wiped before packaging (second stale-artifact path)
#   - KREL and vermagic are asserted, not just printed
#   - single Wi-Fi driver: in-tree RTL8821CU is now disabled in
#     athena_defconfig (delta 0009); only morrownr /work/wifi is built
set -euo pipefail

export LOCALVERSION=-tegra
EXPECT_KREL=5.10.216-tegra
K=/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/kernel-5.10
OUT=/tmp/kb
LOG=/tmp/kb-build.log
cd "$K"
mkdir -p "$OUT"

echo "=== defconfig ==="
make -s O="$OUT" athena_defconfig
grep -q '^CONFIG_RTL8821CU=' "$OUT/.config" && { echo "FATAL: in-tree RTL8821CU still enabled — delta 0009 not applied?"; exit 1; }

echo "=== Image + dtbs + modules (-j6) ==="
if ! make -j6 O="$OUT" Image dtbs modules > "$LOG" 2>&1; then
    echo "FATAL: kernel build failed — last 60 lines:"; tail -60 "$LOG"; exit 1
fi
tail -4 "$LOG"

echo "=== install modules to staging ==="
rm -rf /tmp/modstage; mkdir -p /tmp/modstage
make -s O="$OUT" INSTALL_MOD_PATH=/tmp/modstage modules_install > "$LOG.mi" 2>&1 \
    || { echo "FATAL: modules_install failed:"; tail -30 "$LOG.mi"; exit 1; }

KREL=$(cat "$OUT/include/config/kernel.release")
echo "KREL=$KREL"
[ "$KREL" = "$EXPECT_KREL" ] || { echo "FATAL: KREL=$KREL, expected $EXPECT_KREL"; exit 1; }
[ -d "/tmp/modstage/lib/modules/$KREL" ] || { echo "FATAL: staged module dir missing"; exit 1; }

echo "=== 8821cu wifi module (morrownr, the ONLY Wi-Fi driver) ==="
cd /work/wifi
# clean first: /work/wifi is a persistent host mount — a stale 8821cu.ko (same
# KREL) would satisfy both the -f check and the vermagic assertion below
make -C "$OUT" M=/work/wifi clean > /dev/null 2>&1 || true
rm -f /work/wifi/8821cu.ko
make -C "$OUT" M=/work/wifi KVER="$KREL" ARCH=arm64 modules > "$LOG.wifi" 2>&1 \
    || { echo "FATAL: 8821cu build failed:"; tail -30 "$LOG.wifi"; exit 1; }
[ -f /work/wifi/8821cu.ko ] || { echo "FATAL: 8821cu.ko not produced"; exit 1; }
VM=$(modinfo -F vermagic /work/wifi/8821cu.ko)
case "$VM" in "$KREL "*|"$KREL") echo "vermagic OK: $VM" ;; *) echo "FATAL: vermagic '$VM' != $KREL"; exit 1 ;; esac

echo "=== package artifacts (clean final dir — no stale carry-over) ==="
rm -rf /work/out/final
mkdir -p /work/out/final/modules
cp "$OUT/arch/arm64/boot/Image" /work/out/final/
cp "$OUT"/arch/arm64/boot/dts/nvidia/*p2151*.dtb /work/out/final/
cp /work/wifi/8821cu.ko /work/out/final/modules/
tar czf "/work/out/final/modules-$KREL.tar.gz" -C /tmp/modstage "lib/modules/$KREL"
( cd /work/out/final && sha256sum Image ./*.dtb "modules-$KREL.tar.gz" modules/8821cu.ko > SHA256SUMS )
echo "=== DONE ==="
ls -la /work/out/final/ /work/out/final/modules/
cat /work/out/final/SHA256SUMS
echo "NOTE: the wipe above removed any previous jp5-initrd from out/final —"
echo "      re-run tools/phase4/build-jp5-initrd.sh NOW (fixed order: always"
echo "      full-build first, then build-jp5-initrd) before staging."
