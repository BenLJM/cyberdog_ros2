#!/bin/bash
# =============================================================================
#  判决实验：绕开 argus，直接走 v4l2 取流
#
#  由来：JP4 在线对照(同板同固件、唯一变量是内核)的 ftrace 显示，JP4 工作时
#  走的是 **v4l2 层**：tegra_channel_set_power(111) / camera_common_s_power(122)
#  / vi5_power_on(38) / ov13b10_set_gain(68) / ov13b10_set_exposure(30)，
#  而 JP5 上这些全是 0。
#  再读 R32 源码 `vi5_channel_start_streaming()`，确认 **R32 的 v4l2 层是骑在
#  capture 驱动之上的**（它自己调 vi_channel_open_ex / vi_capture_setup），
#  也就是说 JP4 的工作路径 = v4l2 → capture，JP5 的 argus 路径 = 直接 capture。
#
#  于是这个实验把剩余问题空间对半劈开：
#    · v4l2 取到帧  ⇒ 内核/硬件/RCE 固件整条链是通的，问题纯在 argus 怎么用
#                     capture chardev（是另一个、可能小得多的问题）
#    · v4l2 也零帧  ⇒ 问题在 argus 之下，继续挖内核/固件
#
#  ⚠️ 红线：出厂栈全程停着；不触碰 active 的 camera_server；不动电机。
# =============================================================================
set -u
crumb() { echo "<4>V4L2: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
VID=/dev/video1        # ov13b10 2-0036 = 主 AI 相机
T=/sys/kernel/debug/tracing
SDBG=/sys/kernel/debug/camera-ov13b10_e/streaming

crumb "step1 停栈 → 武装门控 → rebind"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 4
echo 1 > "$PARAM"
echo bc00000.rtcpu > "$DRV/unbind"; sleep 2
echo bc00000.rtcpu > "$DRV/bind"; sleep 4

crumb "step2 v4l2 能力与格式"
echo "-- 设备 --";   v4l2-ctl -d $VID --info 2>&1 | grep -iE "Driver|Card|Bus" | sed 's/^/   /'
echo "-- 支持的格式 --"; v4l2-ctl -d $VID --list-formats-ext 2>&1 | head -20 | sed 's/^/   /'
echo "-- 当前格式 --"; v4l2-ctl -d $VID --get-fmt-video 2>&1 | sed 's/^/   /'

crumb "step3 开追踪"
echo 8192 > $T/buffer_size_kb 2>/dev/null
echo > $T/trace
echo 1 > $T/events/tegra_rtcpu/enable 2>/dev/null
echo 1 > $T/tracing_on
echo "   取流前 streaming=$(cat $SDBG 2>/dev/null || echo N/A)"

crumb "step4 v4l2 取流（5 帧，30 秒超时）"
echo "===V4L2-STREAM-START==="
timeout 30 v4l2-ctl -d $VID --set-ctrl bypass_mode=0 2>&1 | sed 's/^/   /'
timeout 40 v4l2-ctl -d $VID --stream-mmap --stream-count=5 --stream-to=/tmp/v4l2-frames.raw 2>&1 | sed 's/^/   /'
RC=$?
echo "===V4L2-STREAM-END=== 退出码=$RC"
echo "   取流后 streaming=$(cat $SDBG 2>/dev/null || echo N/A)"
echo "   产物: $(ls -l /tmp/v4l2-frames.raw 2>/dev/null || echo '(无)')"
echo 0 > $T/tracing_on

crumb "判决"
echo "── ① 帧文件大小（>0 = 真的取到帧了）──"
SZ=$(stat -c %s /tmp/v4l2-frames.raw 2>/dev/null || echo 0)
echo "   $SZ 字节"
if [ "$SZ" -gt 0 ]; then
    echo "   🏆 v4l2 路取到帧 ⇒ 内核/硬件/RCE 链是通的，问题在 argus 侧"
else
    echo "   ❌ v4l2 路也零帧 ⇒ 问题在 argus 之下"
fi
echo "── ② JP4 上非零、JP5 上为零的那几个函数，这次走没走 ──"
sudo dmesg | grep -oE "r32-[a-z]+" | sort | uniq -c | sed 's/^/   /'
echo "── ③ VI 侧中断 ──"
echo "   vinotify_event=$(grep -c vinotify_event $T/trace 2>/dev/null) nvcsi_intr=$(grep -c nvcsi_intr $T/trace 2>/dev/null)"
echo "── ④ 内核相机日志尾部 ──"
dmesg | grep -iE "vi5|nvcsi|capture|ov13b10|tegra_channel" | tail -20 | sed 's/^/   /'

crumb "step5 收尾（栈交给 stack-doctor 拉起）"
rm -f /tmp/v4l2-frames.raw
crumb "v4l2 direct probe complete"
