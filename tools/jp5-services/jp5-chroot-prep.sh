#!/bin/bash
# 挂载 JP4 rootfs(p1) 并绑定伪文件系统, 供 chroot 栈使用 (幂等)
set -e
mkdir -p /mnt/jp4
mountpoint -q /mnt/jp4 || mount /dev/nvme0n1p1 /mnt/jp4
for d in dev dev/pts dev/shm proc sys; do
  mountpoint -q /mnt/jp4/$d || mount --bind /$d /mnt/jp4/$d
done
mkdir -p /mnt/jp4/run/udev; mountpoint -q /mnt/jp4/run/udev || mount --bind /run/udev /mnt/jp4/run/udev

# CyberDog JP5 (2026-07-26): 绑 /run/dbus 进 chroot。
# 出厂 JP4 的 bluetooth_ros2 走 D-Bus 跟 bluetoothd 通信(GattManager1/LEAdvertisingManager1),
# 没有这个 socket 时 chroot 内任何 D-Bus 客户端都连不上系统总线 ——
# 蓝牙 GATT 链路的唯一硬阻塞就是这一条。
# 顺带修掉 chroot 内 pulseaudio 反复刷的 "Failed to connect to system bus"。
mkdir -p /mnt/jp4/run/dbus
mountpoint -q /mnt/jp4/run/dbus || mount --bind /run/dbus /mnt/jp4/run/dbus

# CyberDog JP5 (2026-07-26 任务D): 挂 params 分区到 chroot 的 /params。
# 出厂 /etc/systemd/ros2.sh 会 mount eMMC 的 params 分区(mmcblk0p12)到 /params 并 chown mi。
# 移植时整条丢了 -> chroot 里 /params 是空目录, 以下出厂消费者全部读不到:
#   libaudio_assistant.so / libaudio_interaction.so -> /params/audio/token.toml, ai_status.toml (小爱同学鉴权+AI开关)
#   athena_tracking/tracking                        -> /params/camera/*.yaml (相机内外参标定, 跟随/VIO 要用)
#   libdecisionmaker_core.so                        -> /params/
# 分区里确实有出厂内容(token.toml 562B + 8 个标定 yaml), 备份见 /home/mi/params-backup-20260726.tgz
PARAMS_DEV=/dev/disk/by-partlabel/params
if [ -e "$PARAMS_DEV" ]; then
  mkdir -p /mnt/jp4/params
  if ! mountpoint -q /mnt/jp4/params; then
    mount -t ext4 "$PARAMS_DEV" /mnt/jp4/params || echo "jp5-chroot-prep: WARN 挂载 params 失败" >&2
  fi
  mountpoint -q /mnt/jp4/params && chown mi:mi /mnt/jp4/params || true
fi

# CyberDog JP5 (2026-07-26): 挂载并绑定出厂 /params 分区 (eMMC p12, partlabel=params)。
# 出厂 JP4 由 /etc/systemd/ros2.sh 挂载, JP5 只搬了 can0/eth0/amixer/nvpmodel。
# 消费者: libaudio_assistant.so / libaudio_interaction.so -> /params/audio/{ai_status,token}.toml
#         athena_tracking/tracking -> /params/camera (出厂标定)
# 注意: 绝不自动 mkfs (出厂脚本里那个分支是致命的), 只挂已存在的 ext4。
mkdir -p /params
mountpoint -q /params || mount -t ext4 -o defaults /dev/disk/by-partlabel/params /params
mkdir -p /mnt/jp4/params
mountpoint -q /mnt/jp4/params || mount --bind /params /mnt/jp4/params
