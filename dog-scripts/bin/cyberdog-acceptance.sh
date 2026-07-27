#!/bin/bash
# =============================================================================
#  CyberDog JP5 全家桶验收   用法: cyberdog-acceptance.sh
#  部署路径: /usr/local/bin/cyberdog-acceptance.sh
#
#  设计意图: 重启前后跑**同一份**脚本, 输出逐行 diff 即是回归报告。
#  所以这里只输出稳定的键值对, 不带时间戳/PID 这类每次都会变的东西
#  (uptime 和时钟单独放最后, 它们本来就该变)。
# =============================================================================
set -u
CHROOT=/mnt/jp4
k() { printf "%-26s %s\n" "$1" "$2"; }

echo "──── 内核 / 系统 ────"
k "kernel"          "$(uname -r)"
k "failed_units"    "$(systemctl --failed --no-legend | wc -l)"
k "thermal_enabled" "$(cat /sys/class/thermal/thermal_zone*/mode 2>/dev/null | grep -c enabled)/6"
k "nproc"           "$(nproc)"
k "nvpmodel"        "$(nvpmodel -q 2>/dev/null | tail -1)"
k "rmem_max"        "$(sysctl -n net.core.rmem_max)"
k "zram_devices"    "$(ls -d /sys/block/zram* 2>/dev/null | wc -l)"
k "kernel_oops"     "$(dmesg | grep -ciE 'Unable to handle|Internal error|Call trace')"
k "deferred_probe"  "$(cat /sys/kernel/debug/devices_deferred 2>/dev/null | wc -l)"
k "modules_loaded"  "$(lsmod | tail -n +2 | wc -l)"

echo "──── 设备节点 ────"
k "video_nodes"     "$(ls /dev/video* 2>/dev/null | wc -l)"
k "sound_cards"     "$(grep -c '^ *[0-9] \[' /proc/asound/cards)"
k "can0"            "$(ip -br link show can0 2>/dev/null | awk '{print $2}')"
k "ttyTHS0_owner"   "$(stat -c '%U:%G' /dev/ttyTHS0 2>/dev/null)"
k "touchpad_input"  "$(grep -c synaptics_dsx /proc/bus/input/devices 2>/dev/null)"
k "wlan0"           "$(ip -br addr show wlan0 2>/dev/null | awk '{print $2}')"

echo "──── 音频金标准 ────"
k "I2S5_Mux"        "$(amixer -c 1 cget name='I2S5 Mux' 2>/dev/null | grep -o 'ADMAIF[0-9]*' | head -1)"
k "amp_fault_0x71"  "$(i2cget -y 7 0x2d 0x71 2>/dev/null || echo 'n/a')"

echo "──── 自启服务 ────"
for s in jp5-cyberdog-stack jp5-cyberdog-net jp5-nginx jp5-bluetooth-gatt \
         d455-camera ov-vio cyberdog-sensors fanboy deadman audio-init \
         cyberdog-health cyberdog-timekeeper cyberdog-blackbox-rotate cyberdog-gps-perm; do
    k "svc:$s" "$(systemctl is-active $s 2>/dev/null)/$(systemctl is-enabled $s 2>/dev/null)"
done

echo "──── 黑匣子 ────"
k "blackbox_archives" "$(ls -1 /var/log/cyberdog-blackbox/ 2>/dev/null | wc -l)"
k "blackbox_crash_dirs" "$(ls -1 /var/log/cyberdog-blackbox/ 2>/dev/null | grep -c CRASH)"
k "pstore_unlink"     "$(grep -E '^Unlink' /etc/systemd/pstore.conf 2>/dev/null || echo 'default')"
k "ramoops_cmdline"   "$(grep -c ramoops.mem_address /proc/cmdline)"

echo "──── 运动板链路 ────"
r1=$(cat /sys/class/net/eth0/statistics/rx_packets); sleep 4
r2=$(cat /sys/class/net/eth0/statistics/rx_packets)
k "eth0_rx_pkt_per_s" "$(( (r2-r1)/4 ))"

echo "──── ROS2 (chroot) ────"
chroot "$CHROOT" /bin/su - mi -c "
    source /opt/ros2/cyberdog/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
    export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
    python3 -u -c \"
import time, rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data, QoSProfile
from sensor_msgs.msg import Image, Imu
from ception_msgs.msg import Around, BodyState
rclpy.init(); n=Node('acceptance')
NS='/mi1045904'
c={'infra1':0,'imu':0,'obst':0,'body':0}
n.create_subscription(Image, NS+'/camera/infra1/image_rect_raw', lambda m:c.update(infra1=c['infra1']+1), qos_profile_sensor_data)
n.create_subscription(Imu,   NS+'/camera/imu',                   lambda m:c.update(imu=c['imu']+1),       qos_profile_sensor_data)
n.create_subscription(Around,NS+'/ObstacleDetection',            lambda m:c.update(obst=c['obst']+1),     QoSProfile(depth=10))
n.create_subscription(BodyState,NS+'/BodyState',                 lambda m:c.update(body=c['body']+1),     QoSProfile(depth=10))
t0=time.time()
while time.time()-t0 < 8: rclpy.spin_once(n, timeout_sec=0.05)
el=time.time()-t0
names=len(n.get_node_names())
print('%-26s %d' % ('ros2_node_count', names))
for kk,label in (('infra1','hz:camera_infra1'),('imu','hz:camera_imu'),('obst','hz:ObstacleDetection'),('body','hz:BodyState')):
    print('%-26s %.1f' % (label, c[kk]/el))
rclpy.shutdown()
\"
" 2>/dev/null | grep -v ttyname

echo "──── VIO lifecycle ────"
k "ov_msckf_state" "$(chroot "$CHROOT" /bin/su - mi -c "
    source /opt/ros2/cyberdog/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
    export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
    timeout 25 ros2 lifecycle get /mi1045904/ov_msckf 2>/dev/null | tail -1" 2>/dev/null)"
k "emitter_enabled" "$(chroot "$CHROOT" /bin/su - mi -c "
    source /opt/ros2/cyberdog/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
    export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
    timeout 25 ros2 param get /mi1045904/camera/camera stereo_module.emitter_enabled 2>/dev/null | tail -1" 2>/dev/null)"

echo "──── 会变的量(不参与 diff) ────"
k "uptime_seconds"  "$(cut -d. -f1 /proc/uptime)"
k "date_utc"        "$(date -u '+%Y-%m-%d %H:%M:%S')"
k "cpu_temp_mC"     "$(cat /sys/class/thermal/thermal_zone0/temp)"
k "fan_pwm"         "$(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1 2>/dev/null | head -1)"
k "loadavg"         "$(cut -d' ' -f1-3 /proc/loadavg)"
