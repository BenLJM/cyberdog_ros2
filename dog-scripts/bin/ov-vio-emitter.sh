#!/bin/bash
# =============================================================================
#  D455 红外点阵发射器开关  —— 用法: ov-vio-emitter.sh <0|1>
#  部署路径: /usr/local/bin/ov-vio-emitter.sh  (0755)
#
#  ─── 为什么 VIO 必须把它关掉(2026-07-27 实测, 不是推理) ─────────────────────
#  D455 开 depth 流就会打开 IR 点阵投射器, infra1/infra2 上会叠一层散斑。
#  这层散斑是**跟着相机走**的: 投射器与相机刚性固连, 相机平移时点在物体表面上
#  跟着滑, 点在图像里的位置几乎不变 —— 也就是"没有视差的假特征"。
#  ov_msckf 用 KLT 跟踪, 会牢牢咬住这些假特征, 于是 VIO 认为自己没在动。
#  这不是"精度差一点", 是**结果无效**。
#
#  实测 A/B(infra1 相邻像素绝对差均值, 高频纹理代理):
#      发射器 ON  = 4.152
#      发射器 OFF = 1.376      <- 3 倍差, 就是那层散斑
#
#  ─── 代价(必须知情) ─────────────────────────────────────────────────────────
#  关掉发射器后 depth 退化成**纯被动双目**: 有纹理的场景仍然出深度, 但白墙、
#  暗处、无纹理表面会大片空洞。当前 depth 订阅者数 = 0, 所以代价是零;
#  将来要做基于 depth 的避障时, 需要重新权衡(见 §与 VIO 的取舍)。
#
#  本脚本被 ov-vio.service 的 ExecStartPost(关) 和 ExecStopPost(恢复) 调用,
#  所以"发射器状态"跟随 VIO 的生命周期, `systemctl stop ov-vio` 会自动还原。
# =============================================================================
set -u

VAL="${1:-1}"
CHROOT=/mnt/jp4
log() { echo "[ov-vio-emitter] $*"; }

case "$VAL" in
    0|1) ;;
    *) log "usage: $0 <0|1>"; exit 2 ;;
esac

NS="${OV_VIO_NS:-}"
if [ -z "$NS" ]; then
    raw=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)
    if [ -n "$raw" ]; then NS="mi${raw: -7}"; else NS="mi0000000"; fi
fi
CAM="/${NS}/camera/camera"

# 相机节点可能还没起来 —— 重试几次, 但**永远返回 0**:
# 发射器设不上只是 VIO 质量问题, 不该让整个 unit 起不来(那样连"能跑"都没了)。
for i in 1 2 3 4 5 6; do
    out=$(/usr/sbin/chroot "$CHROOT" /bin/su - mi -c "
        source /opt/ros2/cyberdog/setup.bash 2>/dev/null
        export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=1
        export CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml HOME=/home/mi
        timeout 20 ros2 param set $CAM stereo_module.emitter_enabled $VAL 2>&1 | tail -1
    " 2>/dev/null)
    if echo "$out" | grep -qi "successful"; then
        log "emitter_enabled=$VAL OK (attempt $i)"
        exit 0
    fi
    sleep 5
done

log "WARN could not set emitter_enabled=$VAL (camera node not ready?) - continuing anyway"
exit 0
