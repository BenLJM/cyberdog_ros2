#!/bin/bash
# =============================================================================
#  D455 验收脚本 —— JP5 host 上手工执行, 只读, 不改任何东西
#  部署路径: /usr/local/bin/d455-verify.sh   (0755)
#
#  它回答三个问题:
#    1. unit 起来了吗 / 起了几次 / 有没有撞 StartLimit
#    2. 相机在不在 USB 上, 节点进程在不在, 它的 CPU 在不在动
#    3. **话题真的有数据吗** —— 用 rclpy 显式 BEST_EFFORT 订阅计数,
#       不用 `ros2 topic hz`(无 QoS 适配, 测不了 BEST_EFFORT 话题, LESSONS #23),
#       也不信 `ros2 topic list`(daemon 缓存会展示幽灵话题)。
#       BEST_EFFORT 读者与 reliable / best_effort 写者都兼容, 所以两种 QoS 配置都能测。
#
#  用法: sudo /usr/local/bin/d455-verify.sh [采样秒数, 默认10]
# =============================================================================
set -u
SECS="${1:-10}"

raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
NS="mi${raw: -7}"

echo "== 1. systemd =="
systemctl --no-pager -l status d455-camera.service 2>&1 | head -14
echo
systemctl is-enabled d455-camera.service 2>&1 | sed 's/^/enabled: /'
echo "restart-count: $(systemctl show -p NRestarts --value d455-camera.service 2>/dev/null)"
echo "attempt-file : $(cat /run/d455-camera/attempt 2>/dev/null || echo '-')"

echo
echo "== 2. 硬件 / 进程 =="
lsusb -d 8086: || echo "  !! 8086: 不在 USB 上"
echo "realsense_switch: $(cat /sys/bus/platform/devices/realsense_switch/state 2>/dev/null || echo '-')"
PID=$(pgrep -f "[r]ealsense2_camera_node" | head -1)
if [ -n "${PID:-}" ]; then
  A=$(awk '{print $14+$15}' "/proc/$PID/stat"); sleep 5
  B=$(awk '{print $14+$15}' "/proc/$PID/stat")
  echo "node pid=$PID  cpu_ticks_5s=$(( B - A ))   (出流时应 >> 40)"
else
  echo "  !! realsense2_camera_node 进程不在"
fi
echo "SoC temp: $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) m°C"
RMEM=$(cat /proc/sys/net/core/rmem_max)
echo "net.core.rmem_max: $RMEM  (424x240 深度帧 203520B / 848x480 深度帧 814080B)"
[ "$RMEM" -lt 814080 ] && echo "  ~ 提醒: 该值撑不住 848x480, 见 60-cyberdog-dds-sysctl.conf"

echo
echo "== 3. 话题实测 (rclpy, BEST_EFFORT, ${SECS}s) =="
sudo chroot /mnt/jp4 /bin/su - mi -c "
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
source /opt/ros2/foxy/setup.bash >/dev/null 2>&1
python3 - <<'PY'
import rclpy, time
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from sensor_msgs.msg import Image, Imu

NS = '/${NS}/camera'
SECS = ${SECS}
topics = [(NS+'/depth/image_rect_raw', Image),
          (NS+'/infra1/image_rect_raw', Image),
          (NS+'/infra2/image_rect_raw', Image),
          (NS+'/imu', Imu)]
qos = QoSProfile(depth=10, history=HistoryPolicy.KEEP_LAST,
                 reliability=ReliabilityPolicy.BEST_EFFORT)
rclpy.init()
n = rclpy.create_node('d455_verify')
cnt = {t: 0 for t, _ in topics}
def mk(t):
    def cb(_): cnt[t] += 1
    return cb
for t, ty in topics:
    n.create_subscription(ty, t, mk(t), qos)
t0 = time.time()
while time.time() - t0 < SECS:
    rclpy.spin_once(n, timeout_sec=0.2)
el = time.time() - t0
ok = False
for t, _ in topics:
    hz = cnt[t] / el
    mark = 'OK ' if cnt[t] > 0 else '-- '
    if cnt[t] > 0: ok = True
    print('  %s %-46s %6d msgs  %5.1f Hz' % (mark, t, cnt[t], hz))
print('VERIFY-%s' % ('PASS' if ok else 'FAIL'))
n.destroy_node(); rclpy.shutdown()
PY
" 2>&1 | grep -v "^$"
