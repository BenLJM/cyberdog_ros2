#!/bin/bash
# =============================================================================
#  ov_msckf lifecycle 激活器 —— 由 ov-vio.service 的 ExecStartPost 调用
#  部署路径: /usr/local/bin/ov-vio-activate.sh  (0755)
#
#  ros_subscribe_msckf 是 **managed(lifecycle) 节点**: 起来之后停在 unconfigured,
#  只发一个 /transition_event, 别的什么都不干。必须显式 configure -> activate。
#  (这一点很容易误判成"节点起来了但不出数据 = 坏了")
#
#  失败策略: **响亮地失败**。激活不了的 VIO 就是个占着 CPU 的空进程,
#  让 unit 落 failed 比假装成功好。systemd 那边有 5 次/900s 的限流兜底。
# =============================================================================
set -u

CHROOT=/mnt/jp4
log() { echo "[ov-vio-activate] $*"; }

NS="${OV_VIO_NS:-}"
if [ -z "$NS" ]; then
    raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
    if [ -n "$raw" ]; then NS="mi${raw: -7}"; else NS="mi0000000"; fi
fi
NODE="/${NS}/ov_msckf"

# chroot 里跑一条 ros2 命令的公共外壳
ros2do() {
    /usr/sbin/chroot "$CHROOT" /bin/su - mi -c "
        source /opt/ros2/cyberdog/setup.bash 2>/dev/null
        export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
        export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
        $*
    " 2>/dev/null
}

# --- 等节点出现 ---------------------------------------------------------------
log "waiting for $NODE"
UP=0
for i in $(seq 1 40); do
    if ros2do "timeout 15 ros2 node list" | grep -q "^${NODE}$"; then
        log "node up after ~${i} polls"; UP=1; break
    fi
    sleep 2
done
[ "$UP" = 1 ] || { log "FATAL node never appeared"; exit 1; }

# --- 先关发射器, 再 configure ---------------------------------------------------
# 顺序有讲究: configure 会建订阅并开始吃图, 关发射器要赶在它开始跟踪之前,
# 免得初始化窗口里拿到的是带散斑的帧。
/usr/local/bin/ov-vio-emitter.sh 0 || true

# --- configure -> activate ------------------------------------------------------
log "configure"
out=$(ros2do "timeout 60 ros2 lifecycle set $NODE configure" | tail -1)
log "  -> $out"

log "activate"
out=$(ros2do "timeout 60 ros2 lifecycle set $NODE activate" | tail -1)
log "  -> $out"

# --- 验收: 必须真的到 active, 不看命令返回码, 看状态 ------------------------------
state=$(ros2do "timeout 20 ros2 lifecycle get $NODE" | tail -1)
log "final state: $state"
case "$state" in
    *active*) log "OK - VIO active (等狗动起来才会初始化: IMU 激励需超过 0.4 阈值)"; exit 0 ;;
    *)        log "FATAL lifecycle did not reach active"; exit 1 ;;
esac
