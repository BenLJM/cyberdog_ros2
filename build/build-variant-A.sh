#!/bin/bash
# =============================================================================
#  NVCSI 电源域 —— 变体 A（DT-only）构建
#
#  血的教训#1 的直接应用：kernel-E 把 DT 那半和 C 补丁那半打包在一次重启里，
#  炸了之后无法定位，走了一整轮 RCM 救砖。这次拆开，一次只引入一个变量。
#
#  变体 A = **新 DTB + 现有 good Image**（Image 一个字节都不动）
#  变体 B = **现有 good DTB + 新 Image**（DTB 一个字节都不动）
#  两者天然隔离，因为 extlinux 分别指定 LINUX 和 FDT。
#
#  本脚本只做变体 A：给 nvcsi / vi / vi-thi / isp 加回
#  power-domains(VE/ISPA) + resets + nvcsilp/vi-const 时钟。
# =============================================================================
set -euo pipefail

SRC=/work/src/Linux_for_Tegra/source/public/kernel_src
DTSDIR=$SRC/hardware/nvidia/platform/t19x/jakku/kernel-dts
DTS=$DTSDIR/tegra194-p3668-0001-p2151-0000.dts
OUT=/tmp/kb
DEST=/work/nvcsi-variants/A-dtonly
INC='#include "tegra194-mi-k91-camera-power.dtsi"'

mkdir -p "$DEST"

echo "=== 0. 前置检查：树必须是 pristine ==="
# ⚠️ `grep -c` 在零匹配时返回退出码 1，配合 set -o pipefail 会把
#    「计数为 0」误判成「命令失败」。必须用 `|| true` 兜住再比较数值。
n_dt=$(grep -c 'camera-power.dtsi' "$DTS" || true)
n_c=$(grep -c 'camrtc_device_group_busy' "$SRC/kernel/nvidia/drivers/platform/tegra/rtcpu/device-group.c" || true)
[ "$n_dt" = "0" ] || { echo "FATAL: dts 里已经有 camera-power include($n_dt 处)，树不干净"; exit 1; }
[ "$n_c" = "0" ] || { echo "FATAL: C 补丁残留在树里($n_c 处)，变体会被污染"; exit 1; }
[ -f "$DTSDIR/tegra194-mi-k91-camera-power.dtsi" ] || { echo "FATAL: camera-power.dtsi 不在树里"; exit 1; }
echo "  ✅ 树干净，可以开始"

cp "$DTS" /tmp/dts.orig.$$

cleanup() {
    echo "=== 恢复 dts（外科式，只撤我加的那一行）==="
    cp /tmp/dts.orig.$$ "$DTS"
    rm -f /tmp/dts.orig.$$
    n=$(grep -c 'camera-power.dtsi' "$DTS" || true)
    echo "  回退后 dts 里 camera-power include 行数 = $n （必须是 0）"
}
trap cleanup EXIT

echo "=== 1. 追加 include（0001 补丁的等效内容，手工接在末尾）==="
cat >> "$DTS" <<EOF

/* Restore the R32 camera power/clock/reset topology (VE + ISPA power domains,
 * nvcsilp CIL clock, NVCSI/VI/ISP resets) that R35 deleted.  Without it NVCSI
 * sits powergated and the R32 RCE firmware dies with
 *   rce-noc: Host read timeout at address 303cc  (nvcsi 0x15a00000 + stream 4)
 * MUST be after the SoC dtsi chain so &nvcsi / &vi / &vi_thi / &isp exist.
 * 2026-07-27: split out as VARIANT A (DT only) so it can be proven or ruled
 * out independently of the C-side patches.  See PORT-STATUS.md. */
$INC
EOF
echo "  现在 include 行数 = $(grep -c 'camera-power.dtsi' "$DTS")"

echo "=== 2. 构建 dtbs（增量）==="
cd "$SRC/kernel/kernel-5.10"
make -s O="$OUT" athena_defconfig >/dev/null
make -j6 O="$OUT" dtbs > /tmp/dtb-build.log 2>&1 || { echo "FATAL: dtbs 构建失败"; tail -25 /tmp/dtb-build.log; exit 1; }
echo "  ✅ dtbs 构建成功"

DTB=$(find "$OUT/arch/arm64/boot/dts" -name 'tegra194-p3668-0001-p2151-0000.dtb' | head -1)
[ -n "$DTB" ] || { echo "FATAL: 找不到产出的 dtb"; exit 1; }
cp "$DTB" "$DEST/tegra194-mi-k91.dtb"
echo "  产物: $DEST/tegra194-mi-k91.dtb  ($(stat -c %s "$DEST/tegra194-mi-k91.dtb") 字节)"
sha256sum "$DEST/tegra194-mi-k91.dtb" | tee "$DEST/SHA256SUMS"
