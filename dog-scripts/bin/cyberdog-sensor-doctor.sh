#!/bin/bash
# =============================================================================
#  传感器健康哨兵 —— 对付「使能会运行时退化，重发 ENABLE 救不回来」
#  部署路径: /usr/local/bin/cyberdog-sensor-doctor.sh  (由 .timer 每 5 分钟拉起)
#
#  背景(2026-07-27 实测)：运行约 11 小时后 ObstacleDetection 从 10Hz 掉到 0，
#  CAN 健康、服务端照常应答 success=True，但话题就是 0；DISABLE→ENABLE 强制刷新
#  无效，clientcount 甚至不降 —— MCU 侧状态卡死，唯一恢复手段是重启栈。
#  出厂的 MCU 掉线自愈因 get_regulater_name() 的 snprintf 缺陷从未生效过。
#
#  防呆(照抄 d455-doctor 的验证过的设计)：
#   · 连续 2 次判死才动手(防抖) —— strike 文件在 /run，重启后自动清零
#   · 栈不是 active 就跳过 —— 相机实验会故意停栈，哨兵绝不能和实验打架
#   · SoC ≥85°C 拒绝动手
#   · 动手后 30 分钟冷却期，绝不做重启永动机
#   · 所有判决写 journal + kmsg 面包屑(带 <4>，能进 ramoops)
# =============================================================================
set -u
STATE_DIR=/run/cyberdog-sensor-doctor
STRIKES_F=$STATE_DIR/strikes
LAST_F=$STATE_DIR/last-restart
CHROOT=/mnt/jp4
log() { echo "[sensor-doctor] $*"; }
crumb() { echo "<4>sensor-doctor: $*" > /dev/kmsg 2>/dev/null; }

mkdir -p "$STATE_DIR"

# ── 前置守卫 ──────────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet jp5-cyberdog-stack.service; then
    log "栈不是 active(可能在做实验) — 跳过本轮"
    rm -f "$STRIKES_F"
    exit 0
fi
# 栈刚起来时给出厂节点 + cyberdog-sensors 使能留足时间
UP=$(systemctl show jp5-cyberdog-stack.service -p ActiveEnterTimestampMonotonic --value)
NOW=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
if [ -n "$UP" ] && [ "$UP" != "0" ] && [ $(( (NOW - UP) / 1000000 )) -lt 300 ]; then
    log "栈启动未满 5 分钟 — 跳过本轮"
    exit 0
fi
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
if [ "$TEMP" -ge 85000 ]; then
    log "SoC ${TEMP}m°C ≥85°C — 拒绝动手"
    exit 0
fi

# ── cyberdog-sensors 卡在 failed 的自愈 ──────────────────────────────────────
# 2026-07-28: 栈在短时间内被反复重启(做实验时很常见)会把 cyberdog-sensors 的
# StartLimitBurst=4/600s 预算烧光,之后它就【永久】停在 failed —— systemd 报
# "Start request repeated too quickly",连 systemctl start 都不再执行。
# 光靠 WantedBy 跟随栈重跑救不回来,必须先 reset-failed 清掉限流计数。
if [ "$(systemctl is-failed cyberdog-sensors.service 2>/dev/null)" = "failed" ]; then
    log "cyberdog-sensors 卡在 failed(多半是启动限流) — reset-failed 后重拉"
    systemctl reset-failed cyberdog-sensors.service 2>/dev/null || true
    systemctl start cyberdog-sensors.service 2>/dev/null || true
    exit 0   # 让它自己跑完(oneshot 最长 300s),下一轮再测量
fi

# ── 测量(chroot 无 tty 会吞 stdout —— 抓变量再吐，老坑) ───────────────────────
OUT=$(/usr/sbin/chroot "$CHROOT" /bin/su - mi -c '
    source /opt/ros2/cyberdog/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
    export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
    timeout 40 python3 -u -c "
import time, rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile
from ception_msgs.msg import Around, BodyState
rclpy.init(); n=Node(\"sensor_doctor\")
c={\"o\":0,\"b\":0}
n.create_subscription(Around,   \"/mi1045904/ObstacleDetection\", lambda m:c.__setitem__(\"o\",c[\"o\"]+1), QoSProfile(depth=5))
n.create_subscription(BodyState,\"/mi1045904/BodyState\",         lambda m:c.__setitem__(\"b\",c[\"b\"]+1), QoSProfile(depth=5))
t=time.time()
while time.time()-t<10: rclpy.spin_once(n,timeout_sec=0.1)
print(\"OBST=%d BODY=%d\" % (c[\"o\"], c[\"b\"]))
rclpy.shutdown()
"' 2>/dev/null)
OBST=$(echo "$OUT" | grep -oE "OBST=[0-9]+" | cut -d= -f2)
BODY=$(echo "$OUT" | grep -oE "BODY=[0-9]+" | cut -d= -f2)
[ -n "$OBST" ] || OBST=-1   # 测量本身失败(≠传感器死)
[ -n "$BODY" ] || BODY=-1
log "10s 内 ObstacleDetection=$OBST BodyState=$BODY"

# 测量失败不算 strike(DDS 抖动/负载高都可能)，只记录
if [ "$OBST" = "-1" ]; then
    log "测量失败(非判死) — 跳过"
    exit 0
fi

# ── 判决 ──────────────────────────────────────────────────────────────────────
if [ "$OBST" -gt 0 ] && [ "$BODY" -gt 0 ]; then
    rm -f "$STRIKES_F"
    exit 0
fi

N=$(( $(cat "$STRIKES_F" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$STRIKES_F"
log "判死 strike $N/2 (OBST=$OBST BODY=$BODY)"
crumb "strike $N/2 OBST=$OBST BODY=$BODY"
[ "$N" -ge 2 ] || exit 0

# ── 冷却期检查 ────────────────────────────────────────────────────────────────
LAST=$(cat "$LAST_F" 2>/dev/null || echo 0)
NOW_S=$(cut -d. -f1 /proc/uptime)
if [ $(( NOW_S - LAST )) -lt 1800 ]; then
    log "距上次重启不足 30 分钟 — 冷却期内不动手(传感器保持死亡,需人工介入)"
    crumb "restart suppressed by cooldown - sensors remain DEAD, manual attention needed"
    exit 0
fi

# ── 动手：重启栈(sidecar 们靠 PartOf/WantedBy 自动跟随) ───────────────────────
log "连续 2 次判死 → 重启 jp5-cyberdog-stack(相机/VIO/使能会自动跟随)"
crumb "RESTARTING stack: sensors dead 2 consecutive checks"
echo "$NOW_S" > "$LAST_F"
rm -f "$STRIKES_F"
systemctl restart jp5-cyberdog-stack.service
log "重启已下发；下轮(5 分钟后)复查"
