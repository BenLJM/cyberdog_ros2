#!/bin/bash
# =============================================================================
#  最终验证：门控武装 → 出厂栈自己跑 → 调出厂 camera_service TAKE_PICTURE
#
#  这是本工程真正要支持的场景：出厂 camera_server(active) 收到 ROS service 请求，
#  经 libnvargus → VI_CAPTURE_REQUEST ioctl → reloc pass → RCE。
#  ⚠️ 红线遵守：**不碰 camera_server 的 lifecycle**（它已 active，只发业务 service 请求）
# =============================================================================
set -u
crumb() { echo "<4>R32TP: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
CH=/mnt/jp4

crumb "step1 stop stack, arm gate, rebind rtcpu (栈停着时才动 rtcpu)"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 3
echo 1 > "$PARAM"
echo bc00000.rtcpu > "$DRV/unbind"; sleep 2
echo bc00000.rtcpu > "$DRV/bind"; sleep 3
echo "  ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state) ispa=$(cat /sys/kernel/debug/bpmp/debug/powergate/ispa/state) 门控=$(cat $PARAM)"

crumb "step2 start factory stack, wait for camera_server to reach active"
systemctl start jp5-cyberdog-stack.service
sleep 70

STATE=$(chroot $CH /bin/su - mi -c '
source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
timeout 25 ros2 lifecycle get /mi1045904/camera_server 2>/dev/null | tail -1' 2>/dev/null)
echo "  camera_server: ${STATE:-未知}"

crumb "step3 ===TAKEPIC-START==="
rm -f $CH/home/mi/*.jpg 2>/dev/null
chroot $CH /bin/su - mi -c '
source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
timeout 50 ros2 service call /mi1045904/camera_service interaction_msgs/srv/CameraService "{command: 1, args: \"\"}" 2>&1 | tail -8' 2>/dev/null
crumb "step4 ===TAKEPIC-END==="

echo "════ 判决 ════"
echo "  timed out : $(dmesg | sed -n '/===TAKEPIC-START===/,/===TAKEPIC-END===/p' | grep -c 'timed out' || true)"
echo "  r32-abi   : $(dmesg | sed -n '/===TAKEPIC-START===/,/===TAKEPIC-END===/p' | grep -c 'r32-abi' || true)"
echo "  r32-vi5   : $(dmesg | sed -n '/===TAKEPIC-START===/,/===TAKEPIC-END===/p' | grep -c 'r32-vi5' || true)"
echo "── 产出的图像文件 ──"
find $CH/home/mi $CH/tmp $CH/mnt -maxdepth 2 -newermt '-3 minutes' \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.yuv' \) 2>/dev/null | head -5
echo "── 内核层日志 ──"
dmesg | sed -n '/===TAKEPIC-START===/,/===TAKEPIC-END===/p' | grep -iE "r32-|timed out|vinotify|gone bad|rce-noc" | head -12

crumb "step5 disarm gate (栈继续跑)"
echo 0 > "$PARAM"
crumb "takepicture experiment complete"
