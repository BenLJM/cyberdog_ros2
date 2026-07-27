#!/bin/bash
# =============================================================================
#  NVCSI 电源域 —— 变体 B（C 补丁 only）构建
#
#  变体 B = **现有 good DTB + 新 Image**（DTB 一个字节都不动）
#  只应用 0002/0003/0004 三个 C 补丁：
#    0002 device-group.c   : 补回 R32 的 camrtc_device_group_busy/idle/reset
#    0003 tegra-camera-rtcpu.c: runtime_resume 里 boot 前 busy()、suspend 里 idle()、
#                            poweron 里 deassert_resets 之前 reset()
#    0004 t194.c           : t19_nvcsi_info 加 nvcsilp + poweron_reset + keepalive；
#                            t19_vi5_info 加 vi-const/nvcsi/nvcsilp
#  全部包在 CONFIG_TEGRA_CAPTURE_R32_ABI 里（defconfig:357 = y）。
#
#  ⚠️ 关键：DT 里**没有** power-domains 时，nvhost_module_busy() 只会开时钟、
#  不会触发 genpd 上电。所以变体 B 预期比变体 A 温和 —— 这正是要验证的。
# =============================================================================
set -euo pipefail

SRC=/work/src/Linux_for_Tegra/source/public/kernel_src
DTS=$SRC/hardware/nvidia/platform/t19x/jakku/kernel-dts/tegra194-p3668-0001-p2151-0000.dts
DGC=$SRC/kernel/nvidia/drivers/platform/tegra/rtcpu/device-group.c
OUT=/tmp/kb
DEST=/work/nvcsi-variants/B-conly
PATCHES=/work/nvcsi-power-fix/patches

mkdir -p "$DEST"

echo "=== 0. 前置检查：树必须是 pristine ==="
n_dt=$(grep -c 'camera-power.dtsi' "$DTS" || true)
n_c=$(grep -c 'camrtc_device_group_busy' "$DGC" || true)
[ "$n_dt" = "0" ] || { echo "FATAL: dts 里有 camera-power include($n_dt 处) — 变体 A 没回退干净"; exit 1; }
[ "$n_c" = "0" ] || { echo "FATAL: C 补丁已残留($n_c 处)"; exit 1; }
echo "  ✅ 树干净"

APPLIED=""
cleanup() {
    echo "=== 回退 C 补丁（逆序）==="
    for p in $(echo "$APPLIED" | tr ' ' '\n' | tac); do
        [ -n "$p" ] && (cd "$SRC" && patch -R -p1 --force < "$p" >/dev/null 2>&1) && echo "  已回退 $(basename $p)"
    done
    n=$(grep -c 'camrtc_device_group_busy' "$DGC" || true)
    echo "  回退后 device-group.c 里 busy 出现次数 = $n （必须是 0）"
}
trap cleanup EXIT

echo "=== 1. 应用 0002/0003/0004 ==="
for p in "$PATCHES"/0002-*.patch "$PATCHES"/0003-*.patch "$PATCHES"/0004-*.patch; do
    (cd "$SRC" && patch -p1 --force < "$p" >/dev/null) || { echo "FATAL: $(basename $p) 应用失败"; exit 1; }
    APPLIED="$APPLIED $p"
    echo "  ✅ $(basename $p)"
done
echo "  device-group.c 里 busy 出现次数 = $(grep -c 'camrtc_device_group_busy' "$DGC" || true)"

echo "=== 2. 构建 Image（增量，盯 -Werror）==="
cd "$SRC/kernel/kernel-5.10"
make -s O="$OUT" athena_defconfig >/dev/null
if ! make -j6 O="$OUT" Image > /tmp/imgB-build.log 2>&1; then
    echo "FATAL: Image 构建失败 —— 这三个 C 补丁此前从未单独编译过"
    grep -iE 'error|warning' /tmp/imgB-build.log | tail -25
    exit 1
fi
echo "  ✅ Image 构建成功"
grep -iE '\berror\b|warning:' /tmp/imgB-build.log | tail -10 || true

IMG="$OUT/arch/arm64/boot/Image"
cp "$IMG" "$DEST/Image"
echo "  产物: $DEST/Image  ($(stat -c %s "$DEST/Image") 字节)"

echo "=== 3. 符号验证：R32 契约是否真的编进去了 ==="
for s in camrtc_device_group_busy camrtc_device_group_idle camrtc_device_group_reset nvcsilp; do
    printf "  %-30s %s 次\n" "$s" "$(strings -a "$DEST/Image" | grep -c "$s" || true)"
done
sha256sum "$DEST/Image" | tee "$DEST/SHA256SUMS"
