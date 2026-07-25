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
