#!/bin/bash
set -e
K=/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/kernel-5.10
W=/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/../..    # tree root
cd "$K"
OUT=/tmp/kb
mkdir -p "$OUT"
echo "=== defconfig ==="
make -s O="$OUT" athena_defconfig >/dev/null
echo "=== Image + dtbs + modules (-j6) ==="
make -j6 O="$OUT" Image dtbs modules 2>&1 | tail -6
echo "IMG_RC=${PIPESTATUS[0]}"
echo "=== install modules to staging ==="
rm -rf /tmp/modstage; mkdir -p /tmp/modstage
make -s O="$OUT" INSTALL_MOD_PATH=/tmp/modstage modules_install >/dev/null 2>&1
KREL=$(cat "$OUT/include/config/kernel.release")
echo "KREL=$KREL"
echo "=== 8821cu wifi module (out-of-tree) ==="
cd /work/wifi
make -C "$OUT" M=/work/wifi KVER="$KREL" ARCH=arm64 modules 2>&1 | tail -8 || \
  make KSRC="$OUT" KVER="$KREL" ARCH=arm64 2>&1 | tail -8
echo "WIFI_RC=$?"
ls -la /work/wifi/*.ko 2>/dev/null || echo "no wifi .ko"
echo "=== copy artifacts to /work/out/final ==="
mkdir -p /work/out/final/modules
cp "$OUT/arch/arm64/boot/Image" /work/out/final/
cp "$OUT"/arch/arm64/boot/dts/nvidia/*p2151*.dtb /work/out/final/
cp /work/wifi/*.ko /work/out/final/modules/ 2>/dev/null || true
# tar the installed modules tree (whole kernel modules set)
tar czf /work/out/final/modules-$KREL.tar.gz -C /tmp/modstage lib/modules/"$KREL" 2>/dev/null || echo "module tar skipped"
echo "=== DONE ==="
ls -la /work/out/final/ /work/out/final/modules/
