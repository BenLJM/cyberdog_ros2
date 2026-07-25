#!/bin/bash
# =============================================================================
#  D455 自愈哨兵 —— JP5 host 侧
#  部署路径: /usr/local/bin/d455-doctor.sh   (0755)
#  调用者:   d455-doctor.service <- d455-doctor.timer (每 5 分钟)
#
#  判活方法 = **节点 CPU 时间是否在涨**, 不是 ros2 CLI。理由三条:
#    1. 便宜: 两次读 /proc/<pid>/stat, 不起 python/DDS 参与者;
#       Foxy CLI 在满载下光启动就要 10 秒级(LESSONS #23), 每 5 分钟来一次不划算。
#    2. 准: 已知失效模式恰恰是"进程活着但帧零投递, 节点 CPU 0%"(LESSONS #22)。
#       正常 848x480@30 深度+红外时该进程稳定占 30~60% 一个核。
#    3. 不受 `ros2 topic hz` 的 QoS 适配缺陷 / daemon 幽灵话题干扰。
#
#  三条防呆(对应审计陷阱#2 的热风险):
#    - 连续 2 次判死才动手, 单次抖动不重启
#    - SoC >= 85°C 一律不动手(重启=重新 chroot+加载 202MB 库, 会顶热)
#    - 真正的限流在 unit 的 StartLimitBurst=5/900s, 哨兵打不穿它
# =============================================================================
set -u

UNIT=d455-camera.service
MISS=/run/d455-doctor.miss
ATTEMPT=/run/d455-camera/attempt
MAXTEMP=85000                 # m°C; fanboy 在 92°C 才掐重负载, 这里更保守
SAMPLE_SEC=20
MIN_TICKS=40                  # 20 秒内至少 0.4 秒 CPU, 否则判"完全没在动"

log() { logger -t d455-doctor "$*"; echo "[d455-doctor] $*"; }

systemctl is-active --quiet "$UNIT" || { rm -f "$MISS"; exit 0; }

T=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
if [ "$T" -ge "$MAXTEMP" ]; then
  log "SoC ${T} m°C >= ${MAXTEMP} - skipping check (thermal guard)"
  exit 0
fi

# 括号断字, 避免匹配到自己的命令行(LESSONS #17/#24)
PID=$(pgrep -f "[r]ealsense2_camera_node" | head -1)

alive=1
if [ -z "${PID:-}" ]; then
  alive=0
else
  A=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null || echo "")
  sleep "$SAMPLE_SEC"
  B=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null || echo "")
  if [ -z "$A" ] || [ -z "$B" ]; then
    alive=0
  else
    D=$(( B - A ))
    [ "$D" -lt "$MIN_TICKS" ] && alive=0
    [ "$alive" -eq 1 ] && log "healthy: pid=$PID cpu_ticks_${SAMPLE_SEC}s=$D"
  fi
fi

if [ "$alive" -eq 1 ]; then
  rm -f "$MISS"
  # 连续健康 -> 清尝试计数, 让下一次偶发重启从"不做固件复位"开始
  rm -f "$ATTEMPT" 2>/dev/null || true
  exit 0
fi

M=$(( $(cat "$MISS" 2>/dev/null || echo 0) + 1 ))
echo "$M" > "$MISS"
log "no frame activity (miss=$M/2) pid=${PID:-none}"

if [ "$M" -ge 2 ]; then
  rm -f "$MISS"
  log "restarting $UNIT"
  systemctl restart "$UNIT" || log "restart refused (StartLimit hit?) - leaving it alone"
fi
