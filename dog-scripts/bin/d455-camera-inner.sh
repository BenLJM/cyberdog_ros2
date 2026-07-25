#!/bin/bash
# =============================================================================
#  D455 取流节点 —— chroot(JP4 rootfs) 内执行体
#  部署路径: /mnt/jp4/home/mi/d455-camera-inner.sh   (0755)
#  调用者:   JP5 host 的 /usr/local/bin/d455-camera.sh (由 d455-camera.service 起)
#
#  为什么是这个二进制:
#    /opt/lrs-wrapper 是对 librealsense 2.55.1 头文件重编的 realsense-ros 3.2.3
#    包装器(2026-07-23 落地, 实测 30.2Hz 满速)。它覆盖出厂 3.2.2 包(那个是 2.48
#    时代的, 用 shim 换库会"帧零投递 + 开 IMU 秒死", 见 LESSONS #22)。
#    这里直接 exec 绝对路径的二进制, 不走 `ros2 run`:
#      - 省掉 Foxy CLI 在满载下 10 秒级的 python 启动(LESSONS #23)
#      - 消除 ament 在"出厂包 vs 包装器"之间选错的可能
#
#  环境变量(由外层传入, 都有默认值):
#    D455_PROFILE        depth_ir(默认) | stereo | full | depth_only
#    D455_INITIAL_RESET  true/false —— 第 2 次及以后的启动尝试才 true(见外层)
#    D455_NS             ROS 命名空间前缀, 空则按出厂算法从 DT 序列号推导
#    D455_IMG_QOS        SYSTEM_DEFAULT(默认, =reliable) | SENSOR_DATA(=best_effort)
#    D455_W / D455_H     影像分辨率, 默认 424x240 —— **别随手改成 848x480**, 先读下面
#
#  ─── 2026-07-25 实测钉死的两颗雷(以前从没被记录过) ───────────────────────────
#  雷 A: IMU 速率必须显式 pin 成 gyro=200 / accel=100。
#        不给 fps 时 realsense-ros 会自动挑"最高档"(gyro 400 / accel 200), 而这颗
#        D455(FW 5.12.14.50) 的 HID/iio 通道起不来那两档 ->
#          WARNING backend-hid.cpp HID set_power 1 failed .../iio:device0/buffer/enable
#          [WARN] Hardware Notification: Motion Module failure, Error, Hardware Error
#        -> IMU 直接没数。pin 成 200/100 后实测 /imu = 199.8 Hz, 零告警。
#        (200/100 正是 rs_poc imu 模式用的 librealsense 默认档, 已两次独立验证)
#
#  雷 B: 848x480 的影像**过不了 DDS**, 424x240 能。
#        JP5 host 的 net.core.rmem_max = 212992 B(内核默认)。而
#          848x480 Z16 = 814080 B  >> 208KB  -> 实测 10 秒只收到 1 帧
#          424x240 Z16 = 203520 B  <  208KB  -> 实测 30.1 Hz 满速
#        JP4 出厂 rootfs 的 /etc/sysctl.conf 第 78/79 行本来就写着
#          net.core.rmem_max=26214000 / net.core.rmem_default=26214000
#        —— 但 chroot 不跑 systemd-sysctl, JP5 host 自己也没有这两行, 于是这条
#        出厂调优在移植中**整条丢了**。这是一个纯粹的迁移漏项, 不是相机的问题。
#        想上 848x480: 先装 dog-scripts/systemd/60-cyberdog-dds-sysctl.conf 并
#        `sysctl --system`, 再把 D455_W/D455_H 改成 848/480 复验。
# =============================================================================
# 注意: 这里**故意不写 `set -u`**。ROS2 Foxy 的 setup.bash / colcon 生成的
# local_setup.bash 会读一堆未定义变量(AMENT_TRACE_SETUP_FILES / COLCON_TRACE ...),
# 开了 -u 会在 source 阶段当场退出。jp5-stack-inner.sh 同理也没开。

NODE_BIN=/opt/lrs-wrapper/lib/realsense2_camera/realsense2_camera_node

# ---- ROS2 / DDS 环境: 必须与 jp5-stack-inner.sh 逐字一致 ----------------------
# 差一个变量就是"发现得到但投递不到"的老病(0722 rs_bridge 之谜)。
# 尤其 CYCLONEDDS_URI: 该 xml 里 NetworkInterfaceAddress=lo + AllowMulticast=false
# + Peers=127.0.0.1 + MaxAutoParticipantIndex=200, 不带就跟栈完全不在一个网上。
export ROS_DOMAIN_ID=42 ROS_VERSION=2 ROS_PYTHON_VERSION=3 ROS_DISTRO=foxy
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
# LD_LIBRARY_PATH 必须带 /opt/librealsense-2.55.1/lib:
#   chroot 里 ldconfig 只认识 /usr/lib 的 2.48; 而包装器的 DT_NEEDED 是
#   librealsense2.so.2.55(SONAME 与 2.48 不同, 所以不会串味, 但找不到就起不来)。
# /opt/lrs-wrapper/lib 由下面的 local_setup.bash 再前置一次, 这里显式写上兜底。
export LD_LIBRARY_PATH=/opt/lrs-wrapper/lib:/opt/librealsense-2.55.1/lib:/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib
# shellcheck disable=SC1091
source /opt/ros2/foxy/setup.bash
# shellcheck disable=SC1091
source /opt/ros2/cyberdog/setup.bash
# shellcheck disable=SC1091
source /opt/lrs-wrapper/local_setup.bash

PROFILE="${D455_PROFILE:-depth_ir}"
RESET="${D455_INITIAL_RESET:-false}"
IMG_QOS="${D455_IMG_QOS:-SYSTEM_DEFAULT}"
W="${D455_W:-424}"          # 见雷 B: 改大之前先修 net.core.rmem_max
H="${D455_H:-240}"
GYRO_FPS="${D455_GYRO_FPS:-200.0}"   # 见雷 A: 别改成 400
ACCEL_FPS="${D455_ACCEL_FPS:-100.0}" # 见雷 A: 别改成 200

# ---- 命名空间: 复刻出厂 athena_pycommon.Get_Namespace() 的算法 ---------------
#      ns = "mi" + DT serial-number 末 7 位   (本机 1421621045904 -> mi1045904)
NS="${D455_NS:-}"
if [ -z "$NS" ]; then
  raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
  if [ -n "$raw" ]; then NS="mi${raw: -7}"; else NS="mi0000000"; fi
fi

# ---- 取流档位 ---------------------------------------------------------------
# 硬事实: JP5 上深度+红外1 并发采集 OK(848x480@30 在 **librealsense 层**已由 rs_poc
#   dual 模式 60/60 帧实测通过) —— 但能不能**发到 DDS 上**取决于雷 B 的 rmem_max。
# 注意红外与发射器的取舍: 开了 depth 就开了 IR 点阵投射器, infra1 上会有散斑,
#   纯视觉 VIO 用 infra1 时应改用 stereo 档(不开 depth) 或另行关发射器。
case "$PROFILE" in
  depth_ir)   EN_DEPTH=true;  EN_IR1=true;  EN_IR2=false ;;  # 默认: 出厂 on_dog 的等价组合
  depth_only) EN_DEPTH=true;  EN_IR1=false; EN_IR2=false ;;
  stereo)     EN_DEPTH=false; EN_IR1=true;  EN_IR2=true  ;;  # 立体 VIO(Y8I 单流拆包)
  full)       EN_DEPTH=true;  EN_IR1=true;  EN_IR2=true  ;;
  *) echo "[d455-inner] FATAL unknown D455_PROFILE=$PROFILE" >&2; exit 78 ;;
esac

[ -x "$NODE_BIN" ] || { echo "[d455-inner] FATAL wrapper node missing: $NODE_BIN" >&2; exit 78; }

echo "[d455-inner] ns=/${NS}/camera profile=${PROFILE} ${W}x${H}@30 imu=${GYRO_FPS}/${ACCEL_FPS} initial_reset=${RESET} img_qos=${IMG_QOS}"
RMEM=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
if [ "$(( W * H * 2 ))" -gt "$RMEM" ]; then
  echo "[d455-inner] WARN 单帧深度 $(( W * H * 2 ))B > net.core.rmem_max ${RMEM}B —— 影像大概率投递不出去(雷 B)"
fi

# ---- 起节点 -----------------------------------------------------------------
# 自愈要点(全部靠 realsense-ros 3.2.3 自带能力, 不靠 systemd 重启风车):
#   wait_for_device_timeout=-1  设备没插/没上电 -> 无限等, 不退出不刷屏
#   reconnect_timeout=6         每 6s 重扫一次设备
#   device_type=d455            AI 头顶相机的 tegra VI 节点(video0/1/2)现在也会被
#                               librealsense 枚举进来, 且 rs2_create_device 对它们
#                               直接抛异常; 3.2.3 的 getDevice() 有 try/catch continue,
#                               再叠一层名字正则过滤, 双保险选中 D455。
#   (设备被拔 -> changeDeviceCallback 释放并回到等待态, 进程不死)
exec "$NODE_BIN" --ros-args \
  -r __ns:="/${NS}/camera" \
  -r __node:=camera \
  -p device_type:=d455 \
  -p wait_for_device_timeout:=-1.0 \
  -p reconnect_timeout:=6.0 \
  -p initial_reset:="${RESET}" \
  -p enable_depth:="${EN_DEPTH}" \
  -p depth_width:="${W}" -p depth_height:="${H}" -p depth_fps:=30.0 \
  -p enable_infra1:="${EN_IR1}" -p enable_infra2:="${EN_IR2}" \
  -p infra_width:="${W}" -p infra_height:="${H}" -p infra_fps:=30.0 \
  -p enable_color:=false \
  -p enable_confidence:=false \
  -p enable_fisheye1:=false -p enable_fisheye2:=false \
  -p enable_gyro:=true -p enable_accel:=true \
  -p gyro_fps:="${GYRO_FPS}" -p accel_fps:="${ACCEL_FPS}" \
  -p unite_imu_method:=copy \
  -p linear_accel_cov:=0.01 \
  -p enable_sync:=false \
  -p align_depth:=false \
  -p enable_pointcloud:=false \
  -p tf_publish_rate:=0.0 \
  -p diagnostics_period:=0.0 \
  -p depth_qos:="${IMG_QOS}" \
  -p infra_qos:="${IMG_QOS}"
