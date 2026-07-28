#!/bin/bash
# =============================================================================
#  变体 C —— R32 相机上电契约「运行时开关版」（默认关）
#
#  = 0002(纯函数定义, 无调用点) + 改造后的 0003(三处调用包在默认关的开关里)
#  **故意不含 0004**：0004 给 t19_nvcsi_info / t19_vi5_info 加了 nvcsilp / vi-const
#  等时钟, 而 nvhost_module_init() 里有 clk_prepare_enable() —— 那是在 probe 阶段
#  就会执行的, 没法用运行时开关关掉。先把能关的关掉、单独验证 0003, 再谈 0004。
#
#  预期：这个内核**能正常启动**（开关默认关 ⇒ 行为等价于 pristine + 一段死代码）。
#        危险动作由 userspace 武装：
#          echo 1 > /sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
#        挂死则 hung_task_panic → ramoops 记 call trace → panic=15 热重启 → 参数回 0 → 自愈。
# =============================================================================
set -euo pipefail

# 🔴 2026-07-28 血的教训：没有这个 export，内核版本串会变成 5.10.216+，
# /lib/modules/5.10.216-tegra/ 对不上 → 所有模块(WiFi/USB gadget functions)
# 加载失败 → 狗活着但完全失联，从外面看和 probe 挂死一模一样。
# 变体 B/C 两轮"炸机"实为此假象，各走了一轮 RCM 救砖。
# full-build.sh 一直有这行且带 KREL 断言 —— 快捷脚本绕过它就把坑绕回来了。
export LOCALVERSION=-tegra

SRC=/work/src/Linux_for_Tegra/source/public/kernel_src
DGC=$SRC/kernel/nvidia/drivers/platform/tegra/rtcpu/device-group.c
RTC=$SRC/kernel/nvidia/drivers/platform/tegra/tegra-camera-rtcpu.c
DTS=$SRC/hardware/nvidia/platform/t19x/jakku/kernel-dts/tegra194-p3668-0001-p2151-0000.dts
OUT=/tmp/kb
DEST=/work/nvcsi-variants/C-gated
PATCHES=/work/nvcsi-power-fix/patches

mkdir -p "$DEST"

echo "=== 0. 前置：树必须 pristine ==="
n_dt=$(grep -c 'camera-power.dtsi' "$DTS" || true)
n_c=$(grep -c 'camrtc_device_group_busy' "$DGC" || true)
n_g=$(grep -c 'r32_camera_power' "$RTC" || true)
[ "$n_dt" = "0" ] || { echo "FATAL: dts 残留 camera-power include($n_dt)"; exit 1; }
[ "$n_c" = "0" ] || { echo "FATAL: device-group.c 残留($n_c)"; exit 1; }
[ "$n_g" = "0" ] || { echo "FATAL: rtcpu.c 已被注入($n_g)"; exit 1; }
echo "  ✅ 干净"

cp "$RTC" /tmp/rtc.orig.$$
APPLIED=""
cleanup() {
    echo "=== 回退 ==="
    cp /tmp/rtc.orig.$$ "$RTC"; rm -f /tmp/rtc.orig.$$
    for p in $APPLIED; do (cd "$SRC" && patch -R -p1 --force < "$p" >/dev/null 2>&1) && echo "  已回退 $(basename $p)"; done
    echo "  rtcpu.c 残留 r32_camera_power: $(grep -c 'r32_camera_power' "$RTC" || true) （须 0）"
    echo "  device-group.c 残留 busy:      $(grep -c 'camrtc_device_group_busy' "$DGC" || true) （须 0）"
}
trap cleanup EXIT

echo "=== 1. 应用 0002（纯增量函数定义，无调用点）==="
(cd "$SRC" && patch -p1 --force < "$PATCHES"/0002-*.patch >/dev/null)
APPLIED="$PATCHES/$(basename $(ls $PATCHES/0002-*.patch))"
echo "  device-group.c busy 定义数: $(grep -c 'camrtc_device_group_busy' "$DGC")"

echo "=== 2. 注入运行时开关版调用点 ==="
python3 /work/gate-rtcpu.py

echo "=== 3. 构建 Image（盯 -Werror）==="
cd "$SRC/kernel/kernel-5.10"
make -s O="$OUT" athena_defconfig >/dev/null
if ! make -j6 O="$OUT" Image > /tmp/imgC.log 2>&1; then
    echo "FATAL: 构建失败"; grep -iE '\berror\b' /tmp/imgC.log | tail -20; exit 1
fi
echo "  ✅ 构建成功"
grep -iE '\berror\b|warning:' /tmp/imgC.log | tail -8 || true

cp "$OUT/arch/arm64/boot/Image" "$DEST/Image"
echo "=== 4. 符号验证 ==="
for s in r32_camera_power camrtc_device_group_busy camrtc_device_group_reset nvcsilp; do
    printf "  %-30s %s 次\n" "$s" "$(strings -a "$DEST/Image" | grep -c "$s" || true)"
done
echo "  （nvcsilp 应为 0 —— 变体 C 故意不含 0004）"
ls -l "$DEST/Image" | awk '{print "  产物: "$5" 字节"}'
# 版本串断言：错了必须响亮失败，不能等部署后变成"幽灵失联"
strings -a "$DEST/Image" | grep -m1 "Linux version 5.10.216-tegra " \
    || { echo "FATAL: 版本串不是 5.10.216-tegra！LOCALVERSION 又丢了"; exit 1; }
sha256sum "$DEST/Image" | tee "$DEST/SHA256SUMS"
