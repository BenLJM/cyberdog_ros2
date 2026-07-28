#!/bin/bash
# =============================================================================
#  变体 P —— O + Stage-11：把 CSI 流启动挪到 VI 通道建立【之后】
#
#  O 已让 settle=19(主相机)/28(鱼眼) 正确下发，但 stage9 把 CSI 流开在了
#  nvcsi 上电时 —— 采集通道还不存在就发 R32_TEMP_CHANNEL_ID 的消息，导致
#  随后 ISP 通道建立超时。R32 的真实顺序是先建通道再开流。P = O + stage11。
#
#  N 让 CSI 配置消息真的发出去了(stream=4 port=4 lanes=4 mipi=448000kHz)，
#  但日志里 settle=0 —— stage8 打在了上游的 R35 路径上，实际发消息的是
#  stage3 自建的那份 R32 函数。O = N + stage10，补在正确的位置(预期 19)。
#
#  结构对比: R35 的 capture_channel_config 多了 csi_stream 字段(RCE 据此配
#  NVCSI)，R32 没有 —— R32 时代 NVCSI 由内核经独立 IVC 消息配置。而 ftrace
#  实测 argus 路径下 csi5_* 调用次数为 0 ⇒ NVCSI 从没被配置过。
#  N = M + stage9：校准后主动 tegra_csi_start_streaming() 每个带传感器的通道。
#
#  L 之后校准真的成功了(failed -1 消失)、传感器也在发，但 NVCSI 仍零中断。
#  再看 csi5 发给 RCE 的 CIL 配置: t_hs_settle 直接取 DT 的 0 —— 那是
#  '自动计算'的约定，R35 固件会自己算而 R32 固件不会。窗口为零 ⇒ 永远
#  检测不到 HS 跳变。M = L + stage8，按 csi4 同款公式补算(预期 19)。
#
#  K 让 csi5_mipi_cal 真的跑起来了(lane 掩码 0x3000000 算得完全正确)，但
#  tegra_mipi_calibration() 恒返回 -1 —— R35 把 T194 的 SoC ops 也全做成了
#  空桩(.calibrate = tegra_mipical_no_op { return -1; })。L = K + stage7，
#  按 mipi_cal.c 自己的注释(t19x 寄存器空间同 t18x)换回 T186 的真实现。
#
#  J 已把控制面全打通、传感器也确认在发，但一帧收不到。真因：R35 把 MIPI
#  焊盘校准搬进了 RCE 固件，csi5_mipi_cal 因此是个 `return 0` 空桩 —— 而狗
#  跑的 R32 固件不做校准。stage2 调的那次 `mipi calibrate rc=0` 其实是空操作。
#  K = J + stage6（补出真实现）。DTB 侧还自动带上相机 modules 换回出厂描述
#  （已直接改在 tegra194-camera-p2151.dtsi 里，见 build/dtb-camera-modules.py）。
#
#  内核 = 0002 + gated-0003(gate-rtcpu.py) + Stage-2(stage2-nvcsi.py)
#  DTB  = A(电源拓扑) + nvcsi reg + mipical okay
#  全部危险行为仍关在 r32_camera_power 后面，boot 行为等价 pristine。
# =============================================================================
set -euo pipefail
export LOCALVERSION=-tegra

SRC=/work/src/Linux_for_Tegra/source/public/kernel_src
NVID=$SRC/kernel/nvidia
DTSDIR=$SRC/hardware/nvidia/platform/t19x/jakku/kernel-dts
DTS=$DTSDIR/tegra194-p3668-0001-p2151-0000.dts
CPD=$DTSDIR/tegra194-mi-k91-camera-power.dtsi
OUT=/tmp/kb
DEST=/work/nvcsi-variants/P-timing
PATCHES=/work/nvcsi-power-fix/patches

FILES="$NVID/drivers/platform/tegra/tegra-camera-rtcpu.c \
$NVID/drivers/video/tegra/host/nvcsi/nvcsi-t194.c \
$NVID/drivers/video/tegra/host/nvcsi/nvcsi-t194.h \
$NVID/drivers/video/tegra/host/t194/t194.c \
$NVID/drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c \
$NVID/drivers/media/platform/tegra/camera/vi/vi5_fops.c \
$NVID/drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c \
$NVID/drivers/media/platform/tegra/mipical/mipi_cal.c \
$CPD $DTS"

mkdir -p "$DEST" /tmp/g-orig

echo "=== 0. pristine 检查 ==="
for probe in "camera-power.dtsi:$DTS" "camrtc_device_group_busy:$NVID/drivers/platform/tegra/rtcpu/device-group.c" \
             "r32_camera_power:$NVID/drivers/platform/tegra/tegra-camera-rtcpu.c" \
             "r32-stage2:$NVID/drivers/video/tegra/host/nvcsi/nvcsi-t194.c" \
             "r32-csi5:$NVID/drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c" \
             "r32-vi5:$NVID/drivers/media/platform/tegra/camera/vi/vi5_fops.c" \
             "r32-sync:$NVID/drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c" \
             "r32-mipisoc:$NVID/drivers/media/platform/tegra/mipical/mipi_cal.c"; do
    pat="${probe%%:*}"; f="${probe#*:}"
    n=$(grep -c "$pat" "$f" || true)
    [ "$n" = "0" ] || { echo "FATAL: $f 残留 $pat($n)"; exit 1; }
done
echo "  ✅ 干净"

for f in $FILES; do cp "$f" /tmp/g-orig/$(echo "$f" | tr / _); done
APPLIED=""
cleanup() {
    echo "=== 回退全部 ==="
    for f in $FILES; do cp /tmp/g-orig/$(echo "$f" | tr / _) "$f"; done
    for p in $APPLIED; do (cd "$SRC" && patch -R -p1 --force < "$p" >/dev/null 2>&1) || true; done
    echo "  残留检查: dts=$(grep -c camera-power.dtsi "$DTS" || true) stage2=$(grep -c r32-stage2 "$NVID/drivers/video/tegra/host/nvcsi/nvcsi-t194.c" || true) csi5=$(grep -c r32-csi5 "$NVID/drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c" || true) vi5=$(grep -c r32-vi5 "$NVID/drivers/media/platform/tegra/camera/vi/vi5_fops.c" || true) sync=$(grep -c r32-sync "$NVID/drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c" || true) gate=$(grep -c r32_camera_power "$NVID/drivers/platform/tegra/tegra-camera-rtcpu.c" || true)（都须 0）"
}
trap cleanup EXIT

echo "=== 1. 内核侧：0002 + gate + stage2 ==="
(cd "$SRC" && patch -p1 --force < "$PATCHES"/0002-*.patch >/dev/null)
APPLIED="$PATCHES/$(basename $(ls $PATCHES/0002-*.patch))"
python3 /work/gate-rtcpu.py
python3 /work/stage2-nvcsi.py
python3 /work/stage3-csi5.py
python3 /work/stage4-vi5.py
python3 /work/stage5-dmasync.py
python3 /work/stage6-csi5-mipical.py
python3 /work/stage7-mipical-t194.py
python3 /work/stage8-settletime.py
python3 /work/stage9-csi-stream-start.py
python3 /work/stage10-r32-settle.py
python3 /work/stage11-csistart-timing.py

echo "=== 2. DTB 侧：camera-power.dtsi += nvcsi reg + mipical okay；dts += include ==="
python3 - <<'PY'
import sys
CPD = "/work/src/Linux_for_Tegra/source/public/kernel_src/hardware/nvidia/platform/t19x/jakku/kernel-dts/tegra194-mi-k91-camera-power.dtsi"
s = open(CPD).read()
a = "&nvcsi {\n\tpower-domains"
assert s.count(a) == 1
s = s.replace(a, "&nvcsi {\n"
    "\t/* Stage-2: MMIO aperture back so the kernel can write prod settings\n"
    "\t * (R32 parity).  NOTE this renames the device 13e10000.host1x:nvcsi@...\n"
    "\t * -> 15a00000.nvcsi; devfs_name is pinned to \"nvcsi\" so nvhost is fine. */\n"
    "\treg = <0x0 0x15a00000 0x0 0x00050000>;\n"
    "\tpower-domains", 1)
s += ("\n/* Stage-2: the R35 DT ships mipical DISABLED because the R35 RCE firmware\n"
      " * calibrates the MIPI pads itself.  The factory R32 firmware does not --\n"
      " * the kernel must do it (tegra_csi_mipi_calibrate), which needs this node. */\n"
      "&{/mipical@3990000} {\n\tstatus = \"okay\";\n};\n")
open(CPD, "w").write(s)
print("  ✅ camera-power.dtsi")
PY
cat >> "$DTS" <<'EOF'

/* Variant G (Stage-2): R32 camera power topology + nvcsi reg + mipical.
 * See tegra194-mi-k91-camera-power.dtsi.  Boot-safe: runtime-gated. */
#include "tegra194-mi-k91-camera-power.dtsi"
EOF

echo "=== 3. 构建 Image + dtbs ==="
cd "$SRC/kernel/kernel-5.10"
make -s O="$OUT" athena_defconfig >/dev/null
if ! make -j6 O="$OUT" Image dtbs > /tmp/gbuild.log 2>&1; then
    echo "FATAL: 构建失败"; grep -iE '\berror\b' /tmp/gbuild.log | tail -20; exit 1
fi
echo "  ✅ 构建成功"
grep -iE 'warning:' /tmp/gbuild.log | grep -i "nvcsi\|rtcpu\|t194" | tail -5 || true

cp "$OUT/arch/arm64/boot/Image" "$DEST/Image"
DTB=$(find "$OUT/arch/arm64/boot/dts" -name 'tegra194-p3668-0001-p2151-0000.dtb' | head -1)
cp "$DTB" "$DEST/tegra194-mi-k91.dtb"

echo "=== 4. 断言 ==="
VER=$(strings -a "$DEST/Image" | grep -m1 "Linux version" || true)
echo "  版本串: ${VER:0:70}"
echo "$VER" | grep -q "5.10.216-tegra " || { echo "FATAL: LOCALVERSION 丢了"; exit 1; }
for s in r32_camera_power r32-stage2 r32-csi5 r32-vi5 r32-sync r32-mipical r32-mipisoc r32-settle r32-csistart tegra194_nvcsi_r32_start_streams tegra_camrtc_r32_camera_power_enabled nvcsi-t194-prod; do
    n=$(strings -a "$DEST/Image" | grep -c "$s" || true)
    printf "  %-42s %s\n" "$s" "$n"
    [ "$n" -ge 1 ] || { echo "FATAL: 符号 $s 缺失"; exit 1; }
done
n=$(strings -a "$DEST/Image" | grep -c nvcsilp || true)
[ "$n" = "0" ] || { echo "FATAL: nvcsilp 出现($n) — 0004 混进来了"; exit 1; }
echo "  nvcsilp=0 ✅（仍不含 0004）"

echo "=== 5. DTB 复核（五铁律 + Stage-2 新项）==="
dtc -I dtb -O dts -o /tmp/g.dts "$DEST/tegra194-mi-k91.dtb" 2>/dev/null
ok=1
chk() { local v; v=$(eval "$2"); printf "  %-34s %s\n" "$1" "$v"; [ "$v" = "$3" ] || ok=0; }
chk "map3(须0)"            "grep -c map3 /tmp/g.dts || true"                             "0"
chk "diag@5 disabled(须1)" "awk '/diag@5/,/};/' /tmp/g.dts | grep -c disabled || true"    "1"
chk "legacy hsp 四邮箱"     "grep -c cmd-rx /tmp/g.dts || true"                            "1"
chk "aonclk(须2)"          "grep -c aonclk /tmp/g.dts || true"                            "2"
chk "synaptics okay(须1)"  "awk '/synaptics_dsx/,/};/' /tmp/g.dts | grep -c okay || true"  "1"
chk "nvcsi reg(须1)"       "awk '/nvcsi@15a00000 {/,/^\t\t};/' /tmp/g.dts | grep -c 'reg = <0x00 0x15a00000' || true" "1"
chk "mipical okay(须1)"    "awk '/mipical@3990000/,/};/' /tmp/g.dts | grep -c okay || true" "1"
chk "出厂 badge RBP194(须3)"  "grep -c RBP194 /tmp/g.dts || true"                          "3"
chk "module0=主相机(须1)"    "awk '/module0 {/,/};/' /tmp/g.dts | grep -c ov13b10_bottom || true" "1"
chk "nvcsi power-domains"  "awk '/nvcsi@15a00000 {/,/^\t\t};/' /tmp/g.dts | grep -c power-domains || true" "1"
[ "$ok" = "1" ] || { echo "FATAL: DTB 复核失败"; exit 1; }

sha256sum "$DEST/Image" "$DEST/tegra194-mi-k91.dtb" | tee "$DEST/SHA256SUMS"
