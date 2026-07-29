#!/bin/bash
# =============================================================================
#  变体 AD —— AC + Stage-24：start_streams once 化 + 抑制 PHY_STREAM_CLOSE
#
#  AC 已把主摄做到出厂规格(1280x960@30fps)并转正。全镜头攻坚发现:
#  rebind 后只有第一个流会话能出帧 —— 每次 vi_capture_setup 都重跑
#  start_streams(重校准+对全部端口重发 SET_CONFIG/OPEN),对着在流的 lane
#  重校准(要求 LP 态)就是打断,重复 OPEN 也搞乱固件流状态机。四个判决实验:
#  单路✓ / 流中加第二路✗(两路全坏) / 流完再开第二路✗ / 三路同时✗(mask=0x0)。
#  Stage-24: ①start_streams 加 once+mutex(并发在锁上等第一次做完)
#  ②门控下 csi5_stream_close 不发 PHY_STREAM_CLOSE(keepalive)
#  ③once 标志在 rtcpu runtime_resume(=RCE 重启,流状态清零)时重置。
#
#  AB 让 CSI 侧的 nvhost 上电真的跑了(r32-csipwr: csi_power_on rc=0)，仍零帧。
#  A/B 表里还剩 VI 侧：vi5_power_on/off JP4=38/54 JP5=0/0。
#  R32 的 vi5_power_on 本质 = nvhost_module_add_client + tegra_vi5_power_on，
#  即对 VI 的 nvhost 设备上电。R35 里该函数还挂在 vi_fops 上，但吃
#  struct tegra_channel*(v4l2 通道)，argus 的 fusa-capture 路径没有它；
#  而 struct tegra_vi_channel 里有 ndev，可直接 nvhost_module_busy。
#  顺序: VI 上电 → CSI 上电(stage22) → CSI 开流(stage9/11)。
#
#  ⚠️ 读 R32 的 vi5_channel_start_streaming 得到一条关键旁证：R32 的 v4l2 层
#  是【骑在 capture 驱动之上】的(它自己调 vi_channel_open_ex/vi_capture_setup)，
#  且注释明确写着 "csi stream/sensor devices should be streamon post vi
#  channel setup" —— 与我们 stage11 把开流挪到通道建立之后的顺序一致。
#
#  用自恢复的 JP4 在线对照(同板同固件,唯一变量是内核)ftrace 两边内核相机
#  函数,得到直接 A/B:
#    vi_capture_ivc_status_callback  JP4=324  JP5=0   ← 帧完成回调
#    tegra_csi_s_power/tegra_csi_power JP4=74/74 JP5=0/0
#    csi5_power_on/off               JP4=19/18 JP5=0/0
#    vi5_power_on/off                JP4=38/54 JP5=0/0
#  ⇒ JP4 采集期间反复走 CSI 的 nvhost 上电链,JP5 一次都不走。
#  csi5_power_on 两代实现完全相同(=nvhost_module_busy),它会触发
#  finalize_poweron(stage2 的 prod+校准 / stage19 的 CIL pad 配置)在采集当下执行。
#  stage9/11 只补了'开流'漏了'上电',而 R32 是先上电再开流。
#
#  内核侧已用 R32.5.2 官方源逐函数比对完毕(还原完整仍零帧),转去逐节点比 DTB。
#  在关键节点找到三处缺失: nvcsi 的 interrupts<0 0x77 4>/num-ports<6>、
#  isp 的 reg<0x14800000 0x10000>。clocks/resets/power-domains/prod 的值两边
#  逐字节一致,rtcpu 的 nvidia,camera-devices 也在 —— 只差这三条。
#  ISP 的 reg 与当年 nvcsi 完全平行: R35 删了 MMIO 窗口,stage2 补了 nvcsi 的,
#  没人补 ISP 的。纯 DTB 改动。
#
#  Y 把 R32 原版的 CIL pad 配置补齐了(实测 cila=0x700000 与 R32 逐位一致)
#  但仍零帧。查出交互 bug: pad 配置挂在 finalize_poweron 且被 nvcsi->on
#  守卫只跑一次,而 0004 的 keepalive 让 NVCSI 不再掉电 ⇒ 永不重跑;
#  可 r32-power 的 group_reset 会把 NVCSI 寄存器清掉。R32 上 NVCSI 会在
#  会话间掉电、每次采集前重跑一遍 —— Z 对齐该行为。
#
#  拿到 R32.5.2 公开内核源后一比,发现 stage6 漏了最关键的一半:
#  R32 的 csi5_mipi_cal 在调 tegra_mipi_calibration 之前会写四次 PHY 寄存器,
#  使能 D-PHY 低功耗输入接收器(E_INPUT_LP_*)并解除下电(PD_*),再复位 CIL。
#  stage6 当初刻意跳过了(以为 prod settings 会管) —— 接收器就一直没上电,
#  与实测'NVCSI 一个中断都收不到而 VI 空转超时'精确吻合。
#
#  现场实测: nvcsilp enable_cnt=0 prepare_cnt=0(204MHz 但从没被使能),
#  nvcsi 314MHz(R32 期望 400MHz)。R35 把 nvcsilp 从时钟表里删了 —— 因为它
#  自己的 RCE 固件经 BPMP 编程 NVCSI 时钟;而出厂 R32 固件期待内核使能。
#  没有 CIL 低功耗时钟,CIL 检测不到 LP→HS 跳变 ⇒ 接收端字面意义上什么都
#  看不见,与实测'零中断零帧零错误'完全吻合。DT 侧(camera-power.dtsi)本就
#  已经声明了两个时钟,缺的只是内核侧的时钟表。0004 还带 poweron_reset +
#  keepalive(R32 parity: 别在客户端持有时把 NVCSI 掉电)。
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
DEST=/work/nvcsi-variants/AD-once
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
# 变体 T 新增: 0004 —— nvcsilp 时钟 + poweron_reset/keepalive
# ⚠️ 必须在 stage2 之后打：两者都改 t194.c 的 t19_nvcsi_info，
#    先打 0004 会让 stage2 的锚点(.can_powergate 那段)失配。
(cd "$SRC" && patch -p1 --force < "$PATCHES"/0004-*.patch >/dev/null)
APPLIED="$APPLIED $PATCHES/$(basename $(ls $PATCHES/0004-*.patch))"
python3 /work/stage3-csi5.py
python3 /work/stage4-vi5.py
python3 /work/stage5-dmasync.py
python3 /work/stage6-csi5-mipical.py
python3 /work/stage7-mipical-t194.py
python3 /work/stage8-settletime.py
python3 /work/stage9-csi-stream-start.py
python3 /work/stage10-r32-settle.py
python3 /work/stage11-csistart-timing.py
python3 /work/stage19-csi5-padconfig.py
python3 /work/stage20-recal-on-start.py
python3 /work/stage22-csi-power-on.py
python3 /work/stage23-vi-power-on.py
python3 /work/stage24-stream-once.py

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
python3 /work/stage21-dt-missing-props.py
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
for s in r32_camera_power r32-stage2 r32-csi5 r32-vi5 r32-sync r32-mipical r32-mipisoc r32-settle r32-csistart r32-padcfg r32-recal r32-csipwr r32-vipwr r32-once tegra194_nvcsi_r32_start_streams tegra_camrtc_r32_camera_power_enabled nvcsi-t194-prod; do
    n=$(strings -a "$DEST/Image" | grep -c "$s" || true)
    printf "  %-42s %s\n" "$s" "$n"
    [ "$n" -ge 1 ] || { echo "FATAL: 符号 $s 缺失"; exit 1; }
done
n=$(strings -a "$DEST/Image" | grep -c nvcsilp || true)
[ "$n" -ge 1 ] || { echo "FATAL: nvcsilp 缺失 — 0004 没打上"; exit 1; }
echo "  nvcsilp=$n ✅（0004 已打上，本变体的核心改动）"

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
chk "nvcsi interrupts(须1)"  "awk '/nvcsi@15a00000 {/,/^\t\t};/' /tmp/g.dts | grep -c 'interrupts =' || true" "1"
chk "nvcsi num-ports(须1)"   "awk '/nvcsi@15a00000 {/,/^\t\t};/' /tmp/g.dts | grep -c 'num-ports' || true" "1"
chk "isp reg(须1)"           "awk '/isp@14800000 {/,/^\t\t};/' /tmp/g.dts | grep -c 'reg = <0x00 0x14800000' || true" "1"
chk "nvcsi power-domains"  "awk '/nvcsi@15a00000 {/,/^\t\t};/' /tmp/g.dts | grep -c power-domains || true" "1"
[ "$ok" = "1" ] || { echo "FATAL: DTB 复核失败"; exit 1; }

sha256sum "$DEST/Image" "$DEST/tegra194-mi-k91.dtb" | tee "$DEST/SHA256SUMS"
