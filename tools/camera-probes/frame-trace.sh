#!/bin/bash
# =============================================================================
#  传感器不出帧：用 RCE 固件视角(tegra_rtcpu ftrace)看 MIPI 到底有没有数据
#
#  现状：argus 全栈已起来(EGL/CUDA/芯片ID 三墙已破)，ISP+VI 通道都建好，
#        RCE 固件握手成功(CL2018101701 v2.2)，但
#            SCF : Timeout waiting on frame end sensor guid 0 (NvCaptureViCsiHw.cpp:897)
#            内核: tegra194-vi5: vi capture get status failed
#        = vi_capture_status() 等 RCE 的 IVC 完成通知超时 ⇒ RCE 从没上报采集完成。
#
#  三个关键事件回答三个不同的问题：
#    rtcpu_vinotify_event  —— VI 硬件有没有看到帧起止(FS/FE)？没有=CSI 收不到数据
#    rtcpu_nvcsi_intr      —— MIPI 链路层有没有报错(lane/CRC/ECC/超时)？
#    rtcpu_vinotify_error  —— VI 侧有没有报错(短帧/长帧/溢出)？
#
#  ⚠️ 红线：出厂栈全程停着，起的是全新未配置实例，不触碰 active 的 camera_server。
# =============================================================================
set -u
crumb() { echo "<4>FRTR: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
CH=/mnt/jp4
T=/sys/kernel/debug/tracing

ROSENV='source /opt/ros2/foxy/setup.bash 2>/dev/null; source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/root
export LD_LIBRARY_PATH=/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib'

crumb "step1 停栈 → 武装门控 → rebind"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 4
echo 1 > "$PARAM"
echo bc00000.rtcpu > "$DRV/unbind"; sleep 2
echo bc00000.rtcpu > "$DRV/bind"; sleep 4
echo "   ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state) ispa=$(cat /sys/kernel/debug/bpmp/debug/powergate/ispa/state)"

crumb "step2 打开 RCE 追踪 + 提高固件日志级别"
echo 8192 > $T/buffer_size_kb 2>/dev/null
echo > $T/trace
echo 1 > $T/events/tegra_rtcpu/enable 2>/dev/null && echo "   tegra_rtcpu 事件已开" || echo "   ⚠️ 追踪开启失败"
echo 1 > $T/tracing_on
cat /sys/kernel/debug/camrtc/log-level 2>/dev/null | sed 's/^/   RCE log-level: /'

crumb "step3 起 maincamera 并驱动到 START_LIVE_STREAM"
chroot $CH /bin/bash -c "$ROSENV
export LD_PRELOAD=/opt/nvgpu-r32-shim.so
unset DISPLAY
rm -f /tmp/mc.log
setsid /opt/ros2/cyberdog/lib/athena_camera/maincamera \
  --ros-args -r __node:=camera_server -r __ns:=/mi1045904 \
  </dev/null >/tmp/mc.log 2>&1 &
sleep 12"
chroot $CH /bin/bash -c "$ROSENV
for c in configure activate; do
  timeout 40 ros2 lifecycle set /mi1045904/camera_server \$c >/dev/null 2>&1; sleep 3
done
echo '   ===CAPTURE-START==='
timeout 60 ros2 service call /mi1045904/camera_service interaction_msgs/srv/CameraService \
  '{command: 7, args: \"preview\"}' 2>&1 | grep -iE 'result=' | tail -1"
sleep 10
echo 0 > $T/tracing_on
crumb "===CAPTURE-END==="

echo ""
echo "════════════ 判 决 ════════════"
echo "── ① VI 有没有看到帧(vinotify_event)? ──"
N=$(grep -c "vinotify_event" $T/trace 2>/dev/null || true); echo "   事件总数: $N"
grep "vinotify_event" $T/trace 2>/dev/null | head -12
echo ""
echo "── ② MIPI 链路有没有报错(nvcsi_intr)? ──"
M=$(grep -c "nvcsi_intr" $T/trace 2>/dev/null || true); echo "   中断总数: $M"
grep "nvcsi_intr" $T/trace 2>/dev/null | head -10
echo ""
echo "── ③ VI 侧错误(vinotify_error)? ──"
E=$(grep -c "vinotify_error" $T/trace 2>/dev/null || true); echo "   错误总数: $E"
grep "vinotify_error" $T/trace 2>/dev/null | head -10
echo ""
echo "── ④ RCE 固件自述(rtcpu_string) ──"
grep "rtcpu_string" $T/trace 2>/dev/null | tail -14
echo ""
echo "── ⑤ 内核侧 ──"
dmesg | tail -40 | grep -iE "r32-|vi5|nvcsi|ov13b10|capture|timed out|RCE" | tail -12
echo ""
echo "── ⑥ SCF 侧 ──"
grep -aiE "frame end|Timeout|guid|stream" $CH/tmp/mc.log 2>/dev/null | tail -6

crumb "step4 收尾"
echo 0 > $T/events/tegra_rtcpu/enable 2>/dev/null
pkill -f 'athena_camera/maincamera' 2>/dev/null; sleep 2
echo 0 > "$PARAM"
systemctl start jp5-cyberdog-stack.service
crumb "frame trace complete"
