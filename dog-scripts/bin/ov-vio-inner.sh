#!/bin/bash
# =============================================================================
#  ov_msckf 单目 VIO —— chroot(JP4 rootfs) 内执行体
#  部署路径: /mnt/jp4/home/mi/ov-vio-inner.sh   (0755)
#  调用者:   JP5 host 的 /usr/local/bin/ov-vio.sh (由 ov-vio.service 起)
#
#  ─── 为什么走 `ros2 launch` 而不是直接 exec 二进制 ──────────────────────────
#  d455 那边是直接 exec 二进制的(省 Foxy CLI 的 python 启动)。这里**故意不那样**:
#  `ros_subscribe_msckf` 是个 lifecycle 节点, 它在 on_configure 里会去读约 60 个
#  参数, 少任何一个就当场抛异常。实测漏掉 `stereo_pairs` 的后果:
#      [ERROR] Caught exception in callback for transition 10
#      [ERROR] Original error: stereo_pairs
#  -> configure 失败, 节点停在 unconfigured, 永远不出数据。
#  出厂 launch 文件是这 60 个参数唯一的权威来源(含标定过的 IMU 噪声与外参),
#  手抄一份进 params.yaml 是纯粹的维护负债。所以用出厂 launch, 只覆盖必须覆盖的。
#
#  ─── 🔴 必须覆盖的那一项: 内参 ───────────────────────────────────────────────
#  出厂 launch 把内参**硬编码**成 640x480 的值:
#      cam0_wh = [640, 480]
#      cam0_k  = [388.3648681640625, 388.3648681640625, 319.376953125, 240.9917755126953]
#  而 D455 现在跑在出厂档位 **848x480**(2026-07-26 由 rmem_max 修复解锁), 真值是:
#      848x480, fx=fy=429.7658, cx=427.4072, cy=236.4622   <- 实测自 camera_info
#  内参错了 VIO **不会报任何错**, 只会安静地输出错误轨迹。cx 差了 108 个像素。
#  => 本脚本从 camera_info 实测值覆盖。若哪天改回 640x480, 这里也要跟着改
#     (或者更好: 让 OV_VIO_* 环境变量留空, 走下面的自动探测)。
#
#  ─── 外参不用改 ─────────────────────────────────────────────────────────────
#  出厂 T_C0toI 的平移 [-0.03, 0.007, 0.016] 与 D455 数据手册的 IMU->左红外
#  偏移逐项吻合, 且外参与分辨率无关。保持出厂值。
# =============================================================================
set +u

# ---- ROS2 / DDS 环境: 必须与 jp5-stack-inner.sh / d455-camera-inner.sh 逐字一致 ----
# 差一个变量就是"发现得到但投递不到"的老病。
source /opt/ros2/cyberdog/setup.bash 2>/dev/null
export ROS_DOMAIN_ID=42 ROS_VERSION=2 ROS_PYTHON_VERSION=3 ROS_DISTRO=foxy
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
# systemd 不带 HOME, 而 rcl_logging_spdlog 要用它展开 ~/.ros/log, 缺了直接
# rcutils_expand_user failed -> Failed to initialize logging -> 退出。
# (蓝牙 GATT 那次踩过, 只有真 systemctl start 才暴露)
export HOME="${HOME:-/home/mi}"

NS="${OV_VIO_NS:-}"
if [ -z "$NS" ]; then
    raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
    if [ -n "$raw" ]; then NS="mi${raw: -7}"; else NS="mi0000000"; fi
fi

W="${OV_VIO_W:-848}"
H="${OV_VIO_H:-480}"
K="${OV_VIO_K:-429.7657775879,429.7657775879,427.4072265625,236.4622192383}"

echo "[ov-vio-inner] ns=/${NS} cam0=${W}x${H} k=[${K}] mono"

exec ros2 launch ov_msckf ros2.launch.py \
    namespace:="${NS}" \
    cam0_wh:="[${W}, ${H}]" \
    cam1_wh:="[${W}, ${H}]" \
    cam0_k:="[${K}]" \
    cam1_k:="[${K}]" \
    max_cameras:=1 \
    use_stereo:=false
