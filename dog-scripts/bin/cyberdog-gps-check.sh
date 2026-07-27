#!/bin/bash
# =============================================================================
#  CyberDog GPS 一把梭体检   用法: cyberdog-gps-check.sh [秒数,默认20]
#  部署路径: /usr/local/bin/cyberdog-gps-check.sh
#
#  ─── 先读这段, 能省掉一整轮误判 ────────────────────────────────────────────
#  出厂 GpsPubNode 的发布条件是(scene_detection.cpp: gps_data_receiver_callback):
#      if (gps_nmea->flag == 1 && (lat != 0 || lon != 0))
#  也就是 **没有有效经纬度就一条都不发**。
#  => 室内收不到星时 /SceneDetection 是 0 Hz, 这是**出厂设计的正确行为**,
#     不是"数据链没通"。别再据此去写一个多余的串口->话题桥 ——
#     出厂节点自己就有读线程(scene_detection.cpp:243-250), 而且它**独占着**
#     /dev/ttyTHS0, 再写一个只会互相抢字节。
#
#  真正没验证过的只有一件事: **室外能不能定到星**。把狗抱到露天再跑一次本脚本。
# =============================================================================
set -u
SECS="${1:-20}"
CHROOT=/mnt/jp4

echo "════════ 1. 驱动 / 设备层 ════════"
echo -n "  /dev/ttyTHS0 : "; ls -l /dev/ttyTHS0 2>/dev/null || echo "缺失!"
echo -n "  波特率       : "; stty -F /dev/ttyTHS0 speed 2>/dev/null || echo "?"
echo    "  占用者       : $(fuser -v /dev/ttyTHS0 2>&1 | tail -1 | awk '{print $NF}') (出厂 service_scene_detection 独占是正常的)"
echo    "  nstandby     : $(dmesg 2>/dev/null | grep -c 'SSPBBD.*nstandby is valid') 次确认有效"

echo
echo "════════ 2. 串口活性(采样 ${SECS}s) ════════"
/usr/local/bin/gps-serial-probe.py "$SECS"

echo
echo "════════ 3. ROS 话题层 ════════"
NS=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null)
NS="mi${NS: -7}"
chroot "$CHROOT" /bin/su - mi -c "
    source /opt/ros2/cyberdog/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
    export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
    python3 -u -c \"
import time, rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile
from motion_msgs.msg import Scene
from ception_msgs.srv import GpsSceneNode
rclpy.init(); n=Node('gps_check')
c=n.create_client(GpsSceneNode,'/${NS}/SceneDetection')
if c.wait_for_service(timeout_sec=10.0):
    r=GpsSceneNode.Request(); r.command=0
    f=c.call_async(r); rclpy.spin_until_future_complete(n,f,timeout_sec=15.0)
    print('  GPS_START    :', 'success' if (f.done() and f.result() and f.result().success) else 'FAILED')
else:
    print('  GPS_START    : 服务不在')
got=[]
n.create_subscription(Scene,'/${NS}/SceneDetection',lambda m: got.append(m),QoSProfile(depth=10))
t0=time.time()
while time.time()-t0 < ${SECS}: rclpy.spin_once(n,timeout_sec=0.1)
print('  SceneDetection: %d 条 / ${SECS}s' % len(got))
if got:
    m=got[-1]
    print('  ✅ 定到位置了: type=%s lat=%.6f lon=%.6f' % (m.type, m.lat, m.lon))
else:
    print('  ℹ️ 0 条 —— 室内属正常(发布条件要求有效经纬度)。室外重跑本脚本才有结论。')
rclpy.shutdown()
\"
" 2>&1 | grep -v ttyname
