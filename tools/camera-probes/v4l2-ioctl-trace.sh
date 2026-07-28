#!/bin/bash
# =============================================================================
#  决定性测量：argus/PCL 对 v4l2 节点到底下了什么 ioctl
#
#  已确认：SCF 成功获取了 index 0/1/2 三个 MIPI 相机源(ISP 配置也全加载了),
#          并对 guid 0 下发采集,但 ov13b10 驱动零调用、I2C 无应答(传感器没上电)。
#  待答：argus 有没有通过 v4l2 节点去给传感器上电/开流？下了哪些 ioctl？
#
#  同时用 ftrace function tracer 盯内核侧 ov13b10_*/camera_common_* 是否被调用。
#  ⚠️ 红线：出厂栈停着,全新实例。
# =============================================================================
set -u
crumb() { echo "<4>V4L2T: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
CH=/mnt/jp4
T=/sys/kernel/debug/tracing

ROSENV='source /opt/ros2/foxy/setup.bash 2>/dev/null; source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/root
export LD_LIBRARY_PATH=/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib'

crumb "step1 停栈 → 武装 → rebind"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 4
echo 1 > "$PARAM"
echo bc00000.rtcpu > "$DRV/unbind"; sleep 2
echo bc00000.rtcpu > "$DRV/bind"; sleep 4

crumb "step2 内核侧 function tracer 盯传感器驱动"
echo nop > $T/current_tracer 2>/dev/null
echo > $T/set_ftrace_filter
for p in 'ov13b10_*' 'camera_common_*' 'tegra_channel_*'; do echo "$p" >> $T/set_ftrace_filter 2>/dev/null; done
echo function > $T/current_tracer 2>/dev/null && echo "   function tracer 已开($(wc -l < $T/set_ftrace_filter) 个符号)" || echo "   ⚠️ tracer 开启失败"
echo > $T/trace
echo 1 > $T/tracing_on

crumb "step3 起 maincamera(strace 含 ioctl)"
chroot $CH /bin/bash -c "$ROSENV
export LD_PRELOAD=/opt/nvgpu-r32-shim.so
unset DISPLAY
rm -f /tmp/mc.log /tmp/v4l2.strace
setsid strace -f -e trace=openat,ioctl -o /tmp/v4l2.strace \
  /opt/ros2/cyberdog/lib/athena_camera/maincamera \
  --ros-args -r __node:=camera_server -r __ns:=/mi1045904 \
  </dev/null >/tmp/mc.log 2>&1 &
sleep 15"
chroot $CH /bin/bash -c "$ROSENV
for c in configure activate; do timeout 40 ros2 lifecycle set /mi1045904/camera_server \$c >/dev/null 2>&1; sleep 3; done
timeout 60 ros2 service call /mi1045904/camera_service interaction_msgs/srv/CameraService \
  '{command: 7, args: \"preview\"}' >/dev/null 2>&1"
sleep 5
echo 0 > $T/tracing_on
crumb "===TRACE-END==="

echo ""
echo "════════════ 判 决 ════════════"
echo "── ① 内核:传感器驱动函数被调用了吗 ──"
K=$(grep -cE "ov13b10_|camera_common_|tegra_channel_" $T/trace 2>/dev/null || true)
echo "   调用总数: $K"
grep -oE "(ov13b10_[a-z_]+|camera_common_[a-z_]+|tegra_channel_[a-z_]+)" $T/trace 2>/dev/null | sort | uniq -c | sort -rn | head -12
echo ""
echo "── ② 用户态:各 /dev/video 节点拿到的 fd ──"
grep -aE "openat.*\"/dev/video" $CH/tmp/v4l2.strace 2>/dev/null | sed -E "s/^[0-9]+ +//" | sort -u | head -8
echo ""
echo "── ③ 对 video 节点下的 ioctl(取第一个成功打开的 fd) ──"
FD=$(grep -aE "openat.*\"/dev/video1\", O_RDWR\) = [0-9]+" $CH/tmp/v4l2.strace 2>/dev/null | head -1 | grep -oE "= [0-9]+$" | tr -d "= ")
echo "   /dev/video1 的 fd = ${FD:-未打开}"
[ -n "$FD" ] && grep -aE "ioctl\($FD," $CH/tmp/v4l2.strace 2>/dev/null | sed -E "s/^[0-9]+ +//" | head -18
echo ""
echo "── ④ 所有 VIDIOC 类 ioctl 统计(0x56='V') ──"
grep -aoE "_IOC\(_IOC_[A-Z|_]+, 0x56, 0x[0-9a-f]+, 0x[0-9a-f]+\)" $CH/tmp/v4l2.strace 2>/dev/null | sort | uniq -c | sort -rn | head -12
echo ""
echo "── ⑤ SCF 结论 ──"
grep -aiE "frame start|frame end|guid 0" $CH/tmp/mc.log 2>/dev/null | head -3

crumb "step4 收尾"
echo nop > $T/current_tracer 2>/dev/null; echo > $T/set_ftrace_filter 2>/dev/null
pkill -f 'athena_camera/maincamera' 2>/dev/null; sleep 2
echo 0 > "$PARAM"
systemctl start jp5-cyberdog-stack.service
crumb "v4l2 ioctl trace complete"
