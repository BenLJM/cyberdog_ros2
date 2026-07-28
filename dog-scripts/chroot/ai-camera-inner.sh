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

BIN="${AI_CAM_BIN:-2}"
FPS="${AI_CAM_FPS:-5}"
# 一帧 rgb8 的字节数(降采样后), 用来对 rmem_max 做能力自检
W=$(( 4208 / (2 * BIN) )); H=$(( 3120 / (2 * BIN) ))
NEED=$(( W * H * 3 ))
RMEM=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
echo "[ai-cam-inner] 输出 ${W}x${H} rgb8 = ${NEED}B/帧 @ ${FPS}fps ; rmem_max=${RMEM}B"
if [ "$NEED" -gt "$RMEM" ]; then
  echo "[ai-cam-inner] WARN 单帧 ${NEED}B > rmem_max ${RMEM}B —— 影像会几乎投递不出去。"
  echo "[ai-cam-inner] WARN 装 /etc/sysctl.d/99-cyberdog.conf 再 sysctl --system, 或调大 AI_CAM_BIN。"
fi

exec python3 /opt/ai-camera/ai-camera-node.py
