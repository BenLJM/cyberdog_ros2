#!/bin/bash
# =============================================================================
#  确定性复现器：独立跑 maincamera + strace，抓 SCF PowerService 失败前读了什么
#
#  已打通: EGL(ALLOC_AS 16→64) + CUDA(ALLOC_SPACE 24→32)，见 /opt/nvgpu-r32-shim.so
#  当前墙: libnvscf 的 "Unknown HW element" / "Tegra chip ID not supported"
#          (PowerServiceHwIsp.cpp:74，经 NvRmChipGetCapabilityU32)
#
#  ⚠️ 红线：出厂栈全程停着，这里起的是全新未配置实例，不触碰 active 的 camera_server。
# =============================================================================
set -u
crumb() { echo "<4>MCST: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
CH=/mnt/jp4

ROSENV='source /opt/ros2/foxy/setup.bash 2>/dev/null; source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/root
export LD_LIBRARY_PATH=/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib'

crumb "step1 停栈 → 武装门控 → rebind"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 4
echo 1 > "$PARAM"
echo bc00000.rtcpu > "$DRV/unbind"; sleep 2
echo bc00000.rtcpu > "$DRV/bind"; sleep 3
echo "   ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state) ispa=$(cat /sys/kernel/debug/bpmp/debug/powergate/ispa/state)"

crumb "step2 后台起 maincamera(strace 跟文件访问)"
chroot $CH /bin/bash -c "$ROSENV
export LD_PRELOAD=/opt/nvgpu-r32-shim.so NVGPU_R32_SHIM_DEBUG=1
unset DISPLAY
rm -f /tmp/mc.strace /tmp/mc.log
setsid strace -f -e trace=openat,open,read -o /tmp/mc.strace \
  /opt/ros2/cyberdog/lib/athena_camera/maincamera \
  --ros-args -r __node:=camera_server -r __ns:=/mi1045904 \
  </dev/null >/tmp/mc.log 2>&1 &
sleep 12
pgrep -f 'athena_camera/maincamera' >/dev/null && echo '   maincamera 已起' || echo '   ⚠️ 没起来'"

crumb "step3 configure → activate → START_LIVE_STREAM"
chroot $CH /bin/bash -c "$ROSENV
for c in configure activate; do
  echo \"   lifecycle \$c: \$(timeout 40 ros2 lifecycle set /mi1045904/camera_server \$c 2>&1 | tail -1)\"
  sleep 3
done
echo '   ===SCF-INIT-START==='
timeout 60 ros2 service call /mi1045904/camera_service interaction_msgs/srv/CameraService \
  '{command: 7, args: \"preview\"}' 2>&1 | grep -iE 'response|result=' | tail -2
echo '   ===SCF-INIT-END==='"
sleep 3

echo ""
echo "════════════ 判 决 ════════════"
echo "── maincamera 输出(SCF 报错链) ──"
grep -aiE "SCF|Argus|HW element|chip|CameraProvider|shim" $CH/tmp/mc.log 2>/dev/null | tail -14
echo ""
echo "── 失败(ENOENT)的 sys/proc/etc 访问 ──"
grep -a "= -1" $CH/tmp/mc.strace 2>/dev/null | grep -aE "openat|open\(" \
    | grep -aE "\"/sys/|\"/proc/|\"/etc/|\"/var/" | grep -avE "\.so|locale|gconv|nvidia-application" \
    | sed -E 's/^[0-9]+ +//' | sort -u | head -22
echo ""
echo "── 成功读到的芯片/相机相关文件 ──"
grep -av "= -1" $CH/tmp/mc.strace 2>/dev/null | grep -aE "openat|open\(" \
    | grep -aiE "soc0|fuse|chip|camera|isp|nvcam|\.conf|\.cfg|\.xml" \
    | sed -E 's/^[0-9]+ +//' | sort -u | head -20

crumb "step4 收尾"
pkill -f 'athena_camera/maincamera' 2>/dev/null; pkill -f "strace -f -e trace=openat" 2>/dev/null
sleep 2
echo 0 > "$PARAM"
systemctl start jp5-cyberdog-stack.service
crumb "maincamera strace complete"
