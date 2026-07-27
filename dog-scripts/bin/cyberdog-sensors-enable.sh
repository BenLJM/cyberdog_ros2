#!/bin/bash
# =============================================================================
#  CyberDog 传感器开机自动使能 —— JP5 宿主侧包装器
#  部署路径: /usr/local/bin/cyberdog-sensors-enable.sh  (0755)
#  由 cyberdog-sensors.service 调用。详细背景见 chroot 内的 python 脚本抬头。
# =============================================================================
set -u

CHROOT=/mnt/jp4
INNER=/home/mi/cyberdog-sensor-enable.py
log() { echo "[cyberdog-sensors] $*"; }

if [ ! -x "$CHROOT$INNER" ]; then
    log "FATAL missing $CHROOT$INNER"
    exit 78
fi

NS="${SENSOR_NS:-}"
if [ -z "$NS" ]; then
    raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
    if [ -n "$raw" ]; then NS="mi${raw: -7}"; else NS="mi0000000"; fi
fi

ARGS="--ns /$NS --clientid ${SENSOR_CLIENTID:-9}"
[ "${SENSOR_DISABLE:-0}" = "1" ] && ARGS="$ARGS --disable"

log "ns=/$NS args=$ARGS"

# ⚠️ 不要 exec + 让内层直接往 systemd 的 stdout 写。
# 实测: `chroot ... su - mi -c` 在**没有 tty** 时会把内层的 stdout 吞掉 ——
# 手工跑(有 tty)能看到全部 OK/FAIL 行, 但 systemd 起的时候 journal 里一行都没有,
# 加 `python3 -u` 也没用(不是 python 缓冲的问题, 是 su 那一层)。
# 后果很坏: 这个服务的**全部价值就在于它的自验收输出**, 看不见就等于没做。
# 所以这里先把输出抓进变量, 由本脚本自己 echo 出去 —— 与吞掉的原因无关, 总能work。
# 代价: 不是流式的, 要等跑完(oneshot ~17s, 无所谓)。
OUT=$(/usr/sbin/chroot "$CHROOT" /bin/su - mi -c "
    source /opt/ros2/cyberdog/setup.bash 2>/dev/null
    export ROS_DOMAIN_ID=42 ROS_VERSION=2 ROS_PYTHON_VERSION=3 ROS_DISTRO=foxy
    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
    export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml
    export HOME=/home/mi
    python3 -u $INNER $ARGS
" 2>&1)
rc=$?

# 逐行打出来, 让 journal 里每条 OK/FAIL 都是独立一行
while IFS= read -r line; do
    [ -n "$line" ] && log "$line"
done <<< "$OUT"

log "exit rc=$rc"
exit $rc
