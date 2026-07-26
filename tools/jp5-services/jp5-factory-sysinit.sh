#!/bin/bash
# CyberDog JP5: 补齐出厂 /etc/systemd/ros2.sh 里"一次性系统初始化"中,
# JP5 侧此前没有任何对应实现的那几条(权限/属主类)。
#
# 已由别处覆盖、故意不在这里重复的:
#   amixer 音频路由        -> audio-init.service (走金标准 state 文件, 比 ros2.sh 的散装 amixer 更全)
#   nvpmodel -m 2          -> nvpmodel.service / 已固化
#   can0 / eth0 / 组播路由  -> jp5-cyberdog-net.service
#   timedatectl set-ntp    -> cyberdog-timekeeper.service
#   swapon params 分区的 swap -> 已被 ZRAM(6x646MB) 取代, 不再往 eMMC 上写 swap
#   mount /params           -> jp5-chroot-prep.sh(挂到 chroot 的 /params)
#   insmod rtl8723du        -> 本机是 8821cu, N/A
#   apt-mark hold nvidia-l4t-kernel* -> JP5 内核不走 apt
#   cp /opt/mi/* /opt/nvidia/ -> 故意不做, 见报告(JP4 版 usb-device-mode 脚本缺 R35 的 udc 处理, 覆盖会打断 USB gadget)
#   rm /home/mi/Camera/*    -> 故意不做, 那是机主的照片
set -u
RC=0
log() { echo "factory-sysinit: $*"; }

# --- 1. GPS 串口: 出厂节点 service_scene_detection 以 mi 身份打开 /dev/ttyTHS0 ---
#     出厂是 chmod 777 + chown mi:mi; JP5 上是 root:dialout 660 且 mi 不在 dialout ->
#     GPS 节点永远打不开串口。这里保持出厂语义(0666 已足够, 串口不需要 x 位)。
if [ -e /dev/ttyTHS0 ]; then
    chown mi:mi /dev/ttyTHS0 && chmod 0666 /dev/ttyTHS0 && log "/dev/ttyTHS0 -> mi:mi 0666 OK" || { log "ERROR: /dev/ttyTHS0 设权失败"; RC=1; }
else
    log "WARN: /dev/ttyTHS0 不存在"
fi

# --- 2. GPS nstandby ---
#     ⚠ 出厂节点里硬编码的是 4.9 的 /sys/devices/bcm4775/nstandby;
#     5.10 上平台设备统一挪到了 /sys/devices/platform/ 下 -> 出厂那条 system("echo 0 > ...") 必然失败。
#     sysfs 里没法造兼容软链, 真修需要 LD_PRELOAD 垫片或改节点(见报告路线图)。
#     这里先把 JP5 真实路径的属主/权限按出厂语义摆好, 供手工/后续垫片使用。
NST=/sys/devices/platform/bcm4775/nstandby
if [ -e "$NST" ]; then
    chown mi:mi "$NST" && chmod 0660 "$NST" && log "$NST -> mi:mi 0660 OK (注意: 出厂节点找的是 /sys/devices/bcm4775/nstandby, 路径对不上)" || { log "ERROR: nstandby 设权失败"; RC=1; }
else
    log "WARN: $NST 不存在"
fi

# --- 3. STM32(运动/传感器底板) 电源开关 regulator state 节点 ---
#     出厂: /sys/devices/fixed-regulators/fixed-regulators:reulator@{25,26,29}/regulator/*/state -> mi:mi 0660
#     JP5 真实路径多了 platform/ 一层, 且编号是 @25=rear @26=head @27=bot @28=realsense。
#     用途 = libathena_utils_core.so 的 MCU 掉线断电重启自愈。
#     (注: 该函数在 JP4 上也是坏的 —— get_regulater_name() 三次 snprintf 都从偏移 0 写, 出厂缺陷)
for R in /sys/devices/platform/fixed-regulators/fixed-regulators:reulator@*/regulator/*/state; do
    [ -e "$R" ] || continue
    chown mi:mi "$R" 2>/dev/null && chmod 0660 "$R" 2>/dev/null && log "state 设权 OK: $R" || { log "ERROR: 设权失败 $R"; RC=1; }
done

# --- 4. mi 加入 input 组(出厂 usermod -aG input mi, 用于触摸板/手柄 /dev/input/*) ---
if id -nG mi | tr ' ' '\n' | grep -qx input; then
    log "mi 已在 input 组"
else
    usermod -aG input mi && log "mi 已加入 input 组(下次登录生效)" || { log "ERROR: usermod 失败"; RC=1; }
fi

# --- 5. chroot 内 mi 的 .ssh 属主(出厂 chown mi /home/mi/.ssh -R) ---
if [ -d /mnt/jp4/home/mi/.ssh ]; then
    chown -R mi:mi /mnt/jp4/home/mi/.ssh && log "chroot .ssh 属主 OK" || { log "ERROR: .ssh chown 失败"; RC=1; }
fi

[ "$RC" = 0 ] && log "全部完成" || log "完成但有失败项(rc=$RC)"
exit "$RC"
