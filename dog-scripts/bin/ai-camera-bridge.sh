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
# C++ 二进制是可选的 —— 没有就自动回落 Python 版(inner 脚本里判断)
[ -x "$CHROOT/opt/ai-camera/ai-camera-node" ] || log "没有 C++ 二进制, 将回落 Python 版(跑 ai-camera-build.sh 可编出来)"
# ⚠️ 门控不存在 = 当前内核没带 r32 相机补丁(比如 DEFAULT 的 good 内核)。
# 这不是故障, 是"这个内核上没这功能" —— 干净 exit 0 让 unit 落在 inactive,
# 而不是 78 留一个永久 failed 单元去污染健康检查。
if [ ! -e "$GATE" ]; then
  log "当前内核没有 $GATE —— 不带 r32 相机补丁, AI 相机桥在此内核上无法运行。"
  log "要用 AI 相机需把带补丁的变体(当前是 AC)转正为 DEFAULT, 这是机主的决定。"
  exit 0
fi

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

# --- 产线个体标定 → 针孔近似 env ----------------------------------------------
# /params/camera/*.yaml 是这台狗的产线 MEI 标定(2021-08-27, 检验 flag 全 1)。
# MEI→针孔近似: f = gamma/(1+xi), 主点 = (u0, v0)。个体值与 share 里的通用参考
# 差别很大(主摄 xi 连符号都不同), 必须用个体值。
# 左右对应(DTB badge 铁证): 2-0061=ov7251_l_center → camera_left.yaml;
#                           2-0062=ov7251_front    → camera_right.yaml。
mei_env() {  # $1=yaml路径 $2=env前缀 → echo export 语句
  [ -r "$1" ] || return 0
  awk -v P="$2" '
    /xi:/     {xi=$2} /gamma1:/ {g1=$2} /gamma2:/ {g2=$2}
    /u0:/     {u0=$2} /v0:/     {v0=$2}
    END { if (g1+0 > 0 && g2+0 > 0)
            printf "export %s_FX=%.3f %s_FY=%.3f %s_CX=%.3f %s_CY=%.3f\n",
                   P, g1/(1+xi), P, g2/(1+xi), P, u0, P, v0 }' "$1"
}
eval "$(mei_env /params/camera/camera_AI.yaml   MAIN)"
eval "$(mei_env /params/camera/camera_left.yaml  FE1C)"
eval "$(mei_env /params/camera/camera_right.yaml FE2C)"
log "标定: 主摄 fx=${MAIN_FX:-无} 左鱼眼 fx=${FE1C_FX:-无} 右鱼眼 fx=${FE2C_FX:-无}"

# --- 枚举鱼眼(ov7251 ×2, 变体 AE 起内核支持三路并发) --------------------------
FE1=""; FE2=""
for v in /dev/video*; do
  n=$(cat "/sys/class/video4linux/$(basename "$v")/name" 2>/dev/null || echo '')
  case "$n" in
    *"ov7251 2-0061"*) FE1="$v" ;;
    *"ov7251 2-0062"*) FE2="$v" ;;
  esac
done
log "fisheye_a(2-0061)=$FE1 fisheye_b(2-0062)=$FE2 (空=不起该路)"

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

BIN="${AI_CAM_BIN:-4}"
W="${AI_CAM_W:-1280}"
H="${AI_CAM_H:-960}"
FPS="${AI_CAM_FPS:-30}"
IMPL="${AI_CAM_IMPL:-auto}"
NS="${AI_CAM_NS:-/mi1045904}"
GAIN="${AI_CAM_GAIN:-1.0}"
AUTOLEVEL="${AI_CAM_AUTOLEVEL:-1}"

log "starting node: dev=$DEV impl=$IMPL ${W}x${H}(py 用 bin=$BIN) fps=$FPS ns=$NS autolevel=$AUTOLEVEL"

# --- 进 chroot ----------------------------------------------------------------
# 以 root 跑(不走 `su - mi`): 一是 /dev/video1 是 root:video 660,
# 二是 `chroot … su - mi -c` 没有 tty 会吞掉 stdout(0727 踩过), 日志会消失。
# DDS 侧实测 root 能和出厂栈互相发现(ros2 node list 能看到全部 35 个节点)。
exec /usr/sbin/chroot "$CHROOT" /bin/bash -c \
  "AI_CAM_DEV='$DEV' AI_CAM_IMPL='$IMPL' AI_CAM_W='$W' AI_CAM_H='$H' \
   AI_CAM_BIN='$BIN' AI_CAM_FPS='$FPS' AI_CAM_NS='$NS' \
   AI_CAM_DEV_FE1='$FE1' AI_CAM_DEV_FE2='$FE2' \
   AI_CAM_FX='${MAIN_FX:-}' AI_CAM_FY='${MAIN_FY:-}' AI_CAM_CX='${MAIN_CX:-}' AI_CAM_CY='${MAIN_CY:-}' \
   FE1_FX='${FE1C_FX:-}' FE1_FY='${FE1C_FY:-}' FE1_CX='${FE1C_CX:-}' FE1_CY='${FE1C_CY:-}' \
   FE2_FX='${FE2C_FX:-}' FE2_FY='${FE2C_FY:-}' FE2_CX='${FE2C_CX:-}' FE2_CY='${FE2C_CY:-}' \
   AI_CAM_GAIN='$GAIN' AI_CAM_AUTOLEVEL='$AUTOLEVEL' $INNER"
