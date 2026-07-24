#!/bin/bash
# 挂载 JP4 rootfs(p1) 并绑定伪文件系统, 供 chroot 栈使用 (幂等)
set -e
mkdir -p /mnt/jp4
mountpoint -q /mnt/jp4 || mount /dev/nvme0n1p1 /mnt/jp4
for d in dev dev/pts dev/shm proc sys; do
  mountpoint -q /mnt/jp4/$d || mount --bind /$d /mnt/jp4/$d
done
mkdir -p /mnt/jp4/run/udev; mountpoint -q /mnt/jp4/run/udev || mount --bind /run/udev /mnt/jp4/run/udev
