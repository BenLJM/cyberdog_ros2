#!/bin/bash
# =============================================================================
#  AI 头顶相机 v4l2 → ROS2 桥 —— JP5 host 侧启动器
#  部署路径: /usr/local/bin/ai-camera-bridge.sh   (0755)
#  调用者:   ai-camera-bridge.service (ExecStart)
#
#  职责: chroot 环境兜底 → 武装 r32 相机门控 → rebind rtcpu → 等设备 →
#        设 v4l2 控件 → exec 进 chroot 跑节点。
#
#  ── 为什么必须 rebind rtcpu(2026-07-29 实测) ────────────────────────────────
#  出厂栈里的 camera_server 会先用 argus 试一遍(在 JP5 上必然零帧), 失败后
#  VI/RCE 留在半开状态: 此时 v4l2 取流会「通道建得起来但收不到帧」,
#  dmesg 里是 `err_rec: successfully reset the capture channel` + PHY_STREAM_CLOSE。
#  对 rtcpu 做一次 unbind/bind 让 RCE 干净重来之后, **栈保持运行**也能正常取流
#  (实测 2 帧 52,515,840 字节, 栈仍 active、0 failed)。
#
#  🔴 红线: 不对 active 的 camera_server 调 configure —— 本脚本一次都不碰它。
#
#  退出码约定(与 d455-camera.sh 一致):
#    78  = 缺件/配置错, 人不介入永远修不好 → unit 里 RestartPreventExitStatus=78
#    其它非零 = 运行期故障, 交给 Restart=on-failure + StartLimit 限流
# =============================================================================
set -u

CHROOT=/mnt/jp4
INNER=/home/mi/ai-camera-inner.sh
NODE=/opt/ai-camera/ai-camera-node.py
DEV="${AI_CAM_DEV:-/dev/video1}"
GATE=/sys/module/tegra_camera_rtcpu/parameters/r32_camera_power
RTCPU_DRV=/sys/bus/platform/drivers/tegra186-cam-rtcpu
RTCPU_DEV=bc00000.rtcpu

log() { echo "[ai-cam] $*"; }

# --- chroot 伪文件系统兜底(同 d455: After= 只排序, 不保证挂载还在) -------------
if ! mountpoint -q "$CHROOT/dev" || ! mountpoint -q "$CHROOT/run/udev"; then
  log "chroot binds missing -> running jp5-chroot-prep.sh"
  /usr/local/bin/jp5-chroot-prep.sh || { log "FATAL jp5-chroot-prep.sh failed"; exit 78; }
fi

# --- 前置存在性检查(缺件直接 78) ----------------------------------------------
[ -x "$CHROOT$INNER" ] || { log "FATAL missing $CHROOT$INNER"; exit 78; }
[ -f "$CHROOT$NODE" ]  || { log "FATAL missing $CHROOT$NODE";  exit 78; }
[ -e "$GATE" ]         || { log "FATAL missing $GATE —— 跑的不是带 r32 相机补丁的内核"; exit 78; }

# --- 武装 r32 相机门控 --------------------------------------------------------
# 所有危险行为(电源域/prod/校准/CSI 开流)都关在这个门控后面, 默认关闭 = boot 行为
# 等价 pristine。要取流就必须先打开。
CUR=$(cat "$GATE" 2>/dev/null || echo N)
if [ "$CUR" != "Y" ] && [ "$CUR" != "1" ]; then
  log "arming camera gate ($GATE)"
  echo 1 > "$GATE" || { log "FATAL cannot write $GATE"; exit 78; }
else
  log "camera gate already armed ($CUR)"
fi

# --- rebind rtcpu: 让 RCE 干净重来 --------------------------------------------
# 幂等且对运行中的栈安全(实测)。做一次就够, 不要放进重试循环。
if [ -d "$RTCPU_DRV/$RTCPU_DEV" ]; then
  log "rebinding $RTCPU_DEV"
  echo "$RTCPU_DEV" > "$RTCPU_DRV/unbind" 2>/dev/null || log "WARN unbind failed"
  sleep 2
  echo "$RTCPU_DEV" > "$RTCPU_DRV/bind"   2>/dev/null || log "WARN bind failed"
  sleep 5
else
  log "WARN $RTCPU_DEV not bound to $RTCPU_DRV —— 直接往下走"
fi

# --- 等视频节点出现(rebind 之后 v4l2 节点会重建) -------------------------------
for _ in $(seq 1 30); do
  [ -e "$DEV" ] && break
  sleep 1
done
[ -e "$DEV" ] || { log "FATAL $DEV 一直没出现"; exit 1; }

# 确认它确实是 ov13b10(rebind 后 video 编号可能漂移)
NAME=$(cat "/sys/class/video4linux/$(basename "$DEV")/name" 2>/dev/null || echo '?')
case "$NAME" in
  *ov13b10*) log "$DEV = $NAME ✅" ;;
  *)
    log "WARN $DEV 名字是 '$NAME', 不是 ov13b10 —— 找正确的节点"
    FOUND=""
    for v in /dev/video*; do
      n=$(cat "/sys/class/video4linux/$(basename "$v")/name" 2>/dev/null || echo '')
      case "$n" in *ov13b10*) FOUND="$v"; break ;; esac
    done
    [ -n "$FOUND" ] || { log "FATAL 没有任何 ov13b10 的 v4l2 节点"; exit 1; }
    DEV="$FOUND"; log "改用 $DEV"
    ;;
esac

# --- v4l2 控件: bypass_mode=0(走 VI 而不是旁路给 ISP), 增益 --------------------
# 节点自己不设控件(纯 ctypes 少一块可能出错的代码), 这里用宿主的 v4l2-ctl 设好。
if command -v v4l2-ctl >/dev/null 2>&1; then
  v4l2-ctl -d "$DEV" --set-ctrl bypass_mode=0 >/dev/null 2>&1 || log "WARN bypass_mode 设置失败"
  if [ -n "${AI_CAM_SENSOR_GAIN:-}" ]; then
    v4l2-ctl -d "$DEV" --set-ctrl "gain=$AI_CAM_SENSOR_GAIN" >/dev/null 2>&1 \
      || log "WARN gain 设置失败"
  fi
else
  log "WARN 宿主没有 v4l2-ctl, 跳过控件设置"
fi

BIN="${AI_CAM_BIN:-2}"
FPS="${AI_CAM_FPS:-5}"
NS="${AI_CAM_NS:-/mi1045904}"
GAIN="${AI_CAM_GAIN:-1.0}"
AUTOLEVEL="${AI_CAM_AUTOLEVEL:-1}"

log "starting node: dev=$DEV bin=$BIN fps=$FPS ns=$NS autolevel=$AUTOLEVEL"

# --- 进 chroot ----------------------------------------------------------------
# 以 root 跑(不走 `su - mi`): 一是 /dev/video1 是 root:video 660,
# 二是 `chroot … su - mi -c` 没有 tty 会吞掉 stdout(0727 踩过), 日志会消失。
# DDS 侧实测 root 能和出厂栈互相发现(ros2 node list 能看到全部 35 个节点)。
exec /usr/sbin/chroot "$CHROOT" /bin/bash -c \
  "AI_CAM_DEV='$DEV' AI_CAM_BIN='$BIN' AI_CAM_FPS='$FPS' AI_CAM_NS='$NS' \
   AI_CAM_GAIN='$GAIN' AI_CAM_AUTOLEVEL='$AUTOLEVEL' $INNER"
