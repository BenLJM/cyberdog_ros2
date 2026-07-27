#!/bin/bash
# =============================================================================
#  ov_msckf 单目 VIO —— JP5 宿主侧启动器
#  部署路径: /usr/local/bin/ov-vio.sh  (0755)
#  由 ov-vio.service 的 ExecStart 调用。
#  职责: 探测前置条件 -> 进 chroot 起节点。lifecycle 激活由 ov-vio-activate.sh 做。
# =============================================================================
set -u

CHROOT=/mnt/jp4
INNER=/home/mi/ov-vio-inner.sh
log() { echo "[ov-vio] $*"; }

# --- 前置件检查: 缺文件类错误重试一万次也没用, 用 78 让 systemd 别再拉起 -------
if [ ! -x "$CHROOT$INNER" ]; then
    log "FATAL missing $CHROOT$INNER"
    exit 78
fi
if [ ! -d "$CHROOT/opt/ros2/cyberdog/share/ov_msckf" ]; then
    log "FATAL ov_msckf package not found in chroot"
    exit 78
fi

# --- 等相机话题出现(冷启动竞态) -----------------------------------------------
# After=d455-camera.service 只保证启动顺序, 不保证节点已经在发图。
# 超时也照样往下走: ov_msckf 自己会一直等订阅, 比在这儿失败重启好。
NS="${OV_VIO_NS:-}"
if [ -z "$NS" ]; then
    raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
    if [ -n "$raw" ]; then NS="mi${raw: -7}"; else NS="mi0000000"; fi
fi
log "namespace=/$NS"

# --- 大消息投递能力自检 -------------------------------------------------------
# 与 d455 同一条护栏: rmem_max 被谁改回 208KB 的话, 848x480 影像会几乎投递不出去,
# 而 VIO 的表现会是"一直等不到图", 很容易被误判成 VIO 本身坏了。
RMEM=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
if [ "$RMEM" -lt 1000000 ]; then
    log "WARN net.core.rmem_max=${RMEM}B 偏小, 848x480 影像可能投递不出去"
    log "WARN 检查 /etc/sysctl.d/99-cyberdog.conf 后 sysctl --system"
fi

log "entering chroot"
exec /usr/sbin/chroot "$CHROOT" /bin/su - mi -c \
    "OV_VIO_NS='$NS' OV_VIO_W='${OV_VIO_W:-848}' OV_VIO_H='${OV_VIO_H:-480}' OV_VIO_K='${OV_VIO_K:-}' $INNER"
