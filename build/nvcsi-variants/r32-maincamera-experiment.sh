#!/bin/bash
# =============================================================================
#  路线 A-1：用出厂 maincamera(直接链 libnvargus.so) 验证 reloc pass
#
#  它是本工程真正要支持的用户态，走 VI_CAPTURE_REQUEST ioctl ⇒ reloc pass 生效。
#  ⚠️ 红线：不对 active 的 camera_server 调 configure。本脚本停栈后直接跑二进制，
#     camera_server 此时不 active，不触碰它。
# =============================================================================
set -u
crumb() { echo "<4>R32MC: $*" > /dev/kmsg; echo "── $*"; }
PARAM=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
DEV=bc00000.rtcpu
CH=/mnt/jp4

crumb "step1 stop stack, arm, rebind"
systemctl stop jp5-cyberdog-stack.service 2>/dev/null; sleep 3
echo 1 > "$PARAM"
echo "$DEV" > "$DRV/unbind"; sleep 2
echo "$DEV" > "$DRV/bind"; sleep 3
echo "  ve=$(cat /sys/kernel/debug/bpmp/debug/powergate/ve/state) ispa=$(cat /sys/kernel/debug/bpmp/debug/powergate/ispa/state)"

crumb "step2 start nvargus-daemon (background, no --help!)"
# 关键：nvargus-daemon 必须完全脱离(setsid+全重定向)，否则会拖住 ssh
chroot $CH /bin/bash -lc 'rm -f /tmp/nvargus.log; setsid nvargus-daemon </dev/null >/tmp/nvargus.log 2>&1 &'
sleep 8
PIDS=$(pgrep -f nvargus-daemon | tr "\n" " ")
echo "  nvargus-daemon pid: ${PIDS:-无}"
[ -n "$PIDS" ] || { echo "  ⚠️ daemon 没起来，日志:"; tail -8 $CH/tmp/nvargus.log 2>/dev/null; }

crumb "step3 ===MC-START==="
chroot $CH /bin/bash -lc '
source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/root
export DISPLAY=
cd /tmp
timeout 35 /opt/ros2/cyberdog/lib/athena_camera/maincamera 2>&1 | tail -25
' 2>&1 | grep -v ttyname
crumb "step4 ===MC-END==="

echo "════ 判决 ════"
echo "── 内核层是否被触及(r32-abi / 超时) ──"
dmesg | sed -n "/===MC-START===/,/===MC-END===/p" | \
    grep -iE "r32-abi|r32-vi5|r32-csi5|reloc|timed out|VINOTIFY|gone bad|rce-noc|capture" | head -16
echo "  timed out 次数: $(dmesg | sed -n '/===MC-START===/,/===MC-END===/p' | grep -c 'timed out' || true)"
echo "  r32-abi 次数  : $(dmesg | sed -n '/===MC-START===/,/===MC-END===/p' | grep -c 'r32-abi' || true)"
echo "── nvargus 日志(固件/argus 视角) ──"
tail -18 $CH/tmp/nvargus.log 2>/dev/null

crumb "step5 restore"
pkill -f nvargus-daemon 2>/dev/null
echo "$DEV" > "$DRV/unbind" 2>/dev/null; sleep 1
echo 0 > "$PARAM"
echo "$DEV" > "$DRV/bind" 2>/dev/null; sleep 2
systemctl start jp5-cyberdog-stack.service
crumb "maincamera experiment complete"
