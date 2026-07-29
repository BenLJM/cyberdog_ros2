#!/bin/bash
# =============================================================================
#  AI 头顶相机桥 —— chroot 内启动器
#  部署路径: /mnt/jp4/home/mi/ai-camera-inner.sh   (0755)
#  调用者:   /usr/local/bin/ai-camera-bridge.sh 的最后一行 exec
#
#  只做一件事: 把 DDS 环境摆成和出厂栈完全一致, 然后 exec 节点。
#
#  ── DDS 环境不能省(0725 查明的发现方法) ─────────────────────────────────────
#  出厂栈用 domain 42 + ROS_LOCALHOST_ONLY=1 + cyclonedds.xml, 四项缺一
#  就发现不到对方 —— 话题发出去没人收, 而且不报错, 极难查。
#
#  ⚠️ net.core.rmem_max 必须是出厂值 26214000(不是内核默认 212992)。
#     0725 查明: 停在默认值时所有 ROS2 大消息过不去(D455 848x480 十秒 1 帧)。
#     由 /etc/sysctl.d/99-cyberdog.conf 保证, 这里只做检查告警。
# =============================================================================
exec 2>&1   # stderr 并进 stdout, 让 journal 收得全

# ⚠️ 这里【不能】开 set -u。ROS 的 setup.bash 内部引用了一堆未定义变量
# (AMENT_TRACE_SETUP_FILES / COLCON_TRACE / _colcon_prefix_chain_* ...),
# set -u 会让 bash 在第一行 source 就直接退出 —— 而且因为那行带 2>/dev/null,
# 连报错都看不到, 表现为"服务起来就静默退出、一条日志都没有"。踩过一次。
source /opt/ros2/foxy/setup.bash 2>/dev/null
source /opt/ros2/cyberdog/setup.bash 2>/dev/null

set -u   # 环境备好了再开

export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_LOCALHOST_ONLY=1
export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
export HOME=/root
export PYTHONUNBUFFERED=1
export LD_LIBRARY_PATH="/opt/ros2/foxy/lib:/opt/ros2/cyberdog/lib:/usr/local/lib:${LD_LIBRARY_PATH:-}"

# 实现选择: 有 C++ 二进制就用它(能到出厂的 1280x960@30fps),
# 否则回落到 Python 版(rclpy publish ~30MB/s 的墙, 只能到 526x390@30fps)。
# 用 AI_CAM_IMPL=py 可以强制走 Python 版。
CPPBIN=/opt/ai-camera/ai-camera-node
IMPL="${AI_CAM_IMPL:-auto}"
if [ "$IMPL" = "py" ] || { [ "$IMPL" = "auto" ] && [ ! -x "$CPPBIN" ]; }; then
  IMPL=py
else
  IMPL=cpp
fi

FPS="${AI_CAM_FPS:-30}"
if [ "$IMPL" = "cpp" ]; then
  W="${AI_CAM_W:-1280}"; H="${AI_CAM_H:-960}"
else
  BIN="${AI_CAM_BIN:-4}"
  W=$(( 4208 / (2 * BIN) )); H=$(( 3120 / (2 * BIN) ))
fi
# 一帧 rgb8 的字节数(降采样后), 用来对 rmem_max 做能力自检
NEED=$(( W * H * 3 ))
RMEM=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
echo "[ai-cam-inner] impl=${IMPL} 输出 ${W}x${H} rgb8 = ${NEED}B/帧 @ ${FPS}fps ; rmem_max=${RMEM}B"
if [ "$NEED" -gt "$RMEM" ]; then
  echo "[ai-cam-inner] WARN 单帧 ${NEED}B > rmem_max ${RMEM}B —— 影像会几乎投递不出去。"
  echo "[ai-cam-inner] WARN 装 /etc/sysctl.d/99-cyberdog.conf 再 sysctl --system, 或调小分辨率。"
fi

if [ "$IMPL" = "cpp" ]; then
  export AI_CAM_W="$W" AI_CAM_H="$H"
  # ── 三镜头编排(2026-07-29 变体 AE 起) ────────────────────────────────────
  # 内核已修好端口幂等(r32-once + r32-perport), 三路可并发满速。
  # 鱼眼设备路径由宿主启动器解析后经 AI_CAM_DEV_FE1/FE2 传入; 缺省不起鱼眼。
  # 话题按物理位置命名(DTB badge 铁证: 2-0061=ov7251_l_center=left,
  # 2-0062=ov7251_front=right); 内参用各自产线个体标定(FE1_/FE2_ 环境传入)。
  # 三个进程一损俱损: 任何一个退出就整组退出(KillMode=control-group 收尸),
  # 交给 systemd 重启 —— 桥的 rebind 会让内核状态干净重来。
  PIDS=""
  if [ -n "${AI_CAM_DEV_FE1:-}" ]; then
    AI_CAM_DEV="$AI_CAM_DEV_FE1" AI_CAM_ENCODING=mono8 AI_CAM_W=640 AI_CAM_H=480 \
      AI_CAM_NODE_NAME=ai_camera_fisheye_left AI_CAM_TOPIC_PREFIX=/ai_camera/fisheye_left \
      AI_CAM_FRAME_ID=ai_camera_fisheye_left \
      AI_CAM_FX="${FE1_FX:-}" AI_CAM_FY="${FE1_FY:-}" AI_CAM_CX="${FE1_CX:-}" AI_CAM_CY="${FE1_CY:-}" \
      "$CPPBIN" &
    PIDS="$PIDS $!"
  fi
  if [ -n "${AI_CAM_DEV_FE2:-}" ]; then
    AI_CAM_DEV="$AI_CAM_DEV_FE2" AI_CAM_ENCODING=mono8 AI_CAM_W=640 AI_CAM_H=480 \
      AI_CAM_NODE_NAME=ai_camera_fisheye_right AI_CAM_TOPIC_PREFIX=/ai_camera/fisheye_right \
      AI_CAM_FRAME_ID=ai_camera_fisheye_right \
      AI_CAM_FX="${FE2_FX:-}" AI_CAM_FY="${FE2_FY:-}" AI_CAM_CX="${FE2_CX:-}" AI_CAM_CY="${FE2_CY:-}" \
      "$CPPBIN" &
    PIDS="$PIDS $!"
  fi
  if [ -z "$PIDS" ]; then
    exec "$CPPBIN"          # 没有鱼眼: 保持单进程 exec 语义
  fi
  "$CPPBIN" &               # 主摄
  PIDS="$PIDS $!"
  # wait -n: 任何一个先退就带崩整组(bash 4.4 有)
  wait -n $PIDS
  echo "[ai-cam-inner] 某个相机进程退出, 整组退出交给 systemd 重启"
  kill $PIDS 2>/dev/null
  exit 1
fi
exec python3 /opt/ai-camera/ai-camera-node.py
