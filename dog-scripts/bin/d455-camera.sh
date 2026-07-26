#!/bin/bash
# =============================================================================
#  D455 深度相机自启 —— JP5 host 侧启动器
#  部署路径: /usr/local/bin/d455-camera.sh   (0755)
#  调用者:   d455-camera.service (ExecStart)
#
#  职责: 把 chroot 环境准备到位 -> 传感器电源轨确认 -> 前置存在性检查 ->
#        等 USB 枚举 -> 记尝试次数(决定要不要做固件级复位) -> exec 进 chroot。
#
#  退出码约定:
#    78  = 配置/文件缺失, 属于"人不介入永远修不好"的错。unit 里配了
#          RestartPreventExitStatus=78, 直接停在 failed, 不进重启风车。
#    其它非零 = 运行期故障, 交给 Restart=on-failure + StartLimit 限流处理。
# =============================================================================
set -u

CHROOT=/mnt/jp4
INNER=/home/mi/d455-camera-inner.sh
WRAPPER_NODE=/opt/lrs-wrapper/lib/realsense2_camera/realsense2_camera_node
STATE_DIR=/run/d455-camera          # unit 的 RuntimeDirectory(Preserve=restart)
SW=/sys/bus/platform/devices/realsense_switch/state

log() { echo "[d455] $*"; }

# --- 陷阱#1: chroot 伪文件系统 -------------------------------------------------
# /mnt/jp4 里的 dev(=> /dev/bus/usb, /dev/video*) 、 run/udev(libudev 枚举必需)
# 全靠 jp5-chroot-prep.sh 绑进去。unit 里已有 ExecStartPre, 这里再兜一次底:
# `After=` 只是排序, 不保证挂载还在(比如有人手工 umount 过)。
if ! mountpoint -q "$CHROOT/dev" || ! mountpoint -q "$CHROOT/run/udev"; then
  log "chroot binds missing -> running jp5-chroot-prep.sh"
  /usr/local/bin/jp5-chroot-prep.sh || { log "FATAL jp5-chroot-prep.sh failed"; exit 78; }
fi

# --- 传感器电源轨(reg-userspace-consumer): 幂等兜底 ----------------------------
# 正常由 jp5-cyberdog-net.sh 写。没上电 = USB 上根本不出现 8086:0b5c。
if [ -e "$SW" ] && [ "$(cat "$SW" 2>/dev/null)" != "enabled" ]; then
  log "realsense_switch != enabled -> enabling"
  echo enabled > "$SW" 2>/dev/null || log "WARN cannot write $SW"
fi

# --- 前置存在性检查(缺件直接 78, 不重试) --------------------------------------
[ -x "$CHROOT$INNER" ]        || { log "FATAL missing $CHROOT$INNER";        exit 78; }
[ -x "$CHROOT$WRAPPER_NODE" ] || { log "FATAL missing $CHROOT$WRAPPER_NODE"; exit 78; }
[ -e "$CHROOT/opt/librealsense-2.55.1/lib/librealsense2.so.2.55.1" ] \
  || log "WARN librealsense 2.55.1 not found at expected path (node may still resolve via ldconfig)"

# --- 等 USB 上出现 Intel 设备(冷启动枚举竞态), 最多 60s ------------------------
# 超时也照样往下走: 节点自己 wait_for_device_timeout=-1 会无限等, 比在这儿失败重启好。
for _ in $(seq 1 60); do
  lsusb -d 8086: >/dev/null 2>&1 && { log "D455 present on USB"; break; }
  sleep 1
done
lsusb -d 8086: >/dev/null 2>&1 || log "WARN no 8086: device on USB yet - node will keep waiting"

# --- 陷阱#2: 尝试计数 -> 升级恢复手段 -----------------------------------------
# 第 1 次启动: initial_reset=false (冷启动设备本来就是干净的, 省 5-8 秒)
# 第 2 次起  : initial_reset=true  -> 节点开机先做一次 hardware_reset()
#              这是 librealsense 的固件级软复位(等价于拔插 USB), **不是刷固件**,
#              无变砖风险; 它正是"上次崩溃留下半开状态"的标准解药。
# 计数文件放 RuntimeDirectory: systemd 自动重启时保留, 人为 stop/start 时清零。
# 哨兵观察到健康后也会把它删掉(见 d455-doctor.sh)。
mkdir -p "$STATE_DIR"
N=$(( $(cat "$STATE_DIR/attempt" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$STATE_DIR/attempt"
RESET=false
[ "$N" -ge 2 ] && RESET=true

PROFILE="${D455_PROFILE:-full}"
IMG_QOS="${D455_IMG_QOS:-SYSTEM_DEFAULT}"
NS="${D455_NS:-}"
W="${D455_W:-848}"
H="${D455_H:-480}"
GF="${D455_GYRO_FPS:-200.0}"
AF="${D455_ACCEL_FPS:-100.0}"

# --- 大消息投递能力自检(见 inner 脚本"雷 B") -----------------------------------
RMEM=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
if [ "$(( W * H * 2 ))" -gt "$RMEM" ]; then
  log "WARN depth frame $(( W * H * 2 ))B > net.core.rmem_max ${RMEM}B"
  log "WARN 影像会几乎投递不出去。装 /etc/sysctl.d/60-cyberdog-dds.conf 再 sysctl --system"
fi

log "attempt=$N profile=$PROFILE ${W}x${H} imu=${GF}/${AF} initial_reset=$RESET img_qos=$IMG_QOS"

# --- 进 chroot(与栈同一个 rootfs/同一个 mi 用户/同一套 DDS 环境) ---------------
exec /usr/sbin/chroot "$CHROOT" /bin/su - mi -c \
  "D455_PROFILE='$PROFILE' D455_INITIAL_RESET='$RESET' D455_IMG_QOS='$IMG_QOS' D455_NS='$NS' D455_W='$W' D455_H='$H' D455_GYRO_FPS='$GF' D455_ACCEL_FPS='$AF' $INNER"
