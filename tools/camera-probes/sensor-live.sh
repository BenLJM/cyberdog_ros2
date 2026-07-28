#!/bin/bash
# =============================================================================
#  传感器不出帧：采集进行中的实况取证
#
#  已知：RCE 追踪显示 vinotify_event=0 / nvcsi_intr=0 / vinotify_error=0
#        ⇒ VI/CSI 接收端【什么都没看到】，连 MIPI 错误都没有 = 线上没有数据。
#  待答：传感器到底有没有被下 stream-on？
#
#  三路交叉取证(都在 START_LIVE_STREAM 执行期间采样)：
#    A. ftrace 事件 ov13b10:*        —— 驱动的 s_stream/set_mode 有没有被调用
#    B. debugfs camera-ov13b10_e/streaming —— 驱动自己认为在不在流
#    C. i2ctransfer 读 reg 0x0100    —— 芯片实际的 mode-select 位(1=streaming)
#       (空闲时读会 Remote I/O error,因为传感器断电 —— 这本身也是个信号)
#
#  ⚠️ 红线：出厂栈全程停着,全新未配置实例,不触碰 active 的 camera_server。
# =============================================================================
set -u
crumb() { echo "<4>SNSR: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
CH=/mnt/jp4
T=/sys/kernel/debug/tracing
SDBG=/sys/kernel/debug/camera-ov13b10_e/streaming

ROSENV='source /opt/ros2/foxy/setup.bash 2>/dev/null; source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/root
export LD_LIBRARY_PATH=/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib'

crumb "step1 停栈 → 武装门控 → rebind"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 4
echo 1 > "$PARAM"
echo bc00000.rtcpu > "$DRV/unbind"; sleep 2
echo bc00000.rtcpu > "$DRV/bind"; sleep 4

crumb "step2 开追踪(ov13b10 + tegra_rtcpu)"
echo 8192 > $T/buffer_size_kb 2>/dev/null
echo > $T/trace
echo 1 > $T/events/ov13b10/enable 2>/dev/null && echo "   ov13b10 事件已开" || echo "   ⚠️ ov13b10 事件开启失败"
echo 1 > $T/events/tegra_rtcpu/enable 2>/dev/null
echo 1 > $T/tracing_on
echo "   基线 streaming=$(cat $SDBG 2>/dev/null || echo N/A)  i2c(0x0100)=$(i2ctransfer -y -f 2 w2@0x36 0x01 0x00 r1 2>&1 | tail -1)"

crumb "step3 起 maincamera"
chroot $CH /bin/bash -c "$ROSENV
export LD_PRELOAD=/opt/nvgpu-r32-shim.so
unset DISPLAY
rm -f /tmp/mc.log
setsid /opt/ros2/cyberdog/lib/athena_camera/maincamera \
  --ros-args -r __node:=camera_server -r __ns:=/mi1045904 \
  </dev/null >/tmp/mc.log 2>&1 &
sleep 12"
chroot $CH /bin/bash -c "$ROSENV
for c in configure activate; do timeout 40 ros2 lifecycle set /mi1045904/camera_server \$c >/dev/null 2>&1; sleep 3; done"

crumb "===LIVE-SAMPLING-START==="
# 服务调用放后台,主进程负责在采集窗口内高频采样
chroot $CH /bin/bash -c "$ROSENV
timeout 70 ros2 service call /mi1045904/camera_service interaction_msgs/srv/CameraService \
  '{command: 7, args: \"preview\"}' > /tmp/svc.log 2>&1" &
SVC=$!

echo "   时刻  driver-streaming  i2c-reg-0x0100"
for i in $(seq 1 24); do
    S=$(cat $SDBG 2>/dev/null || echo "-")
    R=$(i2ctransfer -y -f 2 w2@0x36 0x01 0x00 r1 2>/dev/null || echo "无应答")
    printf "   T+%-4s %-16s %s\n" "${i}s" "$S" "$R"
    sleep 1
done
wait $SVC 2>/dev/null
crumb "===LIVE-SAMPLING-END==="
echo 0 > $T/tracing_on

echo ""
echo "════════════ 判 决 ════════════"
echo "── ① 驱动函数有没有被调用(ov13b10 trace 事件) ──"
N=$(grep -c "ov13b10" $T/trace 2>/dev/null || true); echo "   事件数: $N"
grep "ov13b10" $T/trace 2>/dev/null | head -16
echo ""
echo "── ② VI 侧(应仍为 0 才说明问题在传感器上游) ──"
echo "   vinotify_event=$(grep -c vinotify_event $T/trace 2>/dev/null || true)  nvcsi_intr=$(grep -c nvcsi_intr $T/trace 2>/dev/null || true)"
echo ""
echo "── ③ SCF 服务返回 ──"
grep -aiE "result=|response" $CH/tmp/svc.log 2>/dev/null | tail -2
echo ""
echo "── ④ 内核 ──"
dmesg | tail -30 | grep -iE "ov13b10|vi5|nvcsi|r32-|capture|i2c" | tail -10

crumb "step4 收尾"
echo 0 > $T/events/ov13b10/enable 2>/dev/null
echo 0 > $T/events/tegra_rtcpu/enable 2>/dev/null
pkill -f 'athena_camera/maincamera' 2>/dev/null; sleep 2
echo 0 > "$PARAM"
systemctl start jp5-cyberdog-stack.service
crumb "sensor live probe complete"
