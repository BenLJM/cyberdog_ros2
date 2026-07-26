#!/bin/bash
# 挂载 JP4 rootfs(p1) 并绑定伪文件系统, 供 chroot 栈使用 (幂等)
#
# ⚠️ 本脚本是 jp5-cyberdog-stack / jp5-nginx / jp5-bluetooth-gatt 三者共用的
#    ExecStartPre —— 任何一条非零退出会让这三个服务一起起不来。
#    因此:**核心挂载**(jp4 rootfs / dev / proc / sys)失败必须响亮地失败;
#         **可选挂载**(params)失败只告警,绝不能拖垮启动。
#    2026-07-26: 两条并行任务各自加过一段 params 代码,其中一段的 mount 没有
#    兜底,在 set -e 下构成"重启即三服务全灭"的单点。此版本已合并去重。
set -e

# ---- 核心:失败必须致命 ----
mkdir -p /mnt/jp4
mountpoint -q /mnt/jp4 || mount /dev/nvme0n1p1 /mnt/jp4
for d in dev dev/pts dev/shm proc sys; do
  mountpoint -q /mnt/jp4/$d || mount --bind /$d /mnt/jp4/$d
done
mkdir -p /mnt/jp4/run/udev; mountpoint -q /mnt/jp4/run/udev || mount --bind /run/udev /mnt/jp4/run/udev

# /run/dbus: 出厂 bluetooth gattserver 走 D-Bus 跟宿主 bluetoothd 通信
# (org.bluez 的 GattManager1 / LEAdvertisingManager1)。没有它蓝牙 GATT 起不来,
# chroot 内 pulseaudio 也会反复刷 "Failed to connect to system bus"。
mkdir -p /mnt/jp4/run/dbus
mountpoint -q /mnt/jp4/run/dbus || mount --bind /run/dbus /mnt/jp4/run/dbus

# ---- 可选:params 分区(eMMC p12, partlabel=params),失败只告警 ----
# 出厂 JP4 由 /etc/systemd/ros2.sh 挂载,移植时整条丢了 -> chroot 内 /params 为空,
# 以下出厂消费者全部读不到:
#   libaudio_assistant.so / libaudio_interaction.so -> /params/audio/{token,ai_status}.toml (小爱鉴权+AI开关)
#   athena_tracking/tracking                        -> /params/camera/*.yaml (出厂相机内外参标定)
# ⚠️ 绝不自动 mkfs —— 出厂脚本里那个分支是致命的,只挂已存在的 ext4。
# 备份: /home/mi/params-backup-20260726.tgz
params_prep() {
    local dev=/dev/disk/by-partlabel/params
    [ -e "$dev" ] || { echo "jp5-chroot-prep: params 分区不存在,跳过" >&2; return 0; }
    mkdir -p /params /mnt/jp4/params
    # 已由 params.mount unit 或本脚本挂好则短路
    if ! mountpoint -q /params; then
        mount -t ext4 -o defaults "$dev" /params \
            || { echo "jp5-chroot-prep: WARN 挂载 /params 失败(非致命)" >&2; return 0; }
    fi
    chown mi:mi /params 2>/dev/null || true
    # chroot 内:若上一版把设备直接挂在了 /mnt/jp4/params,保持原样即可
    mountpoint -q /mnt/jp4/params \
        || mount --bind /params /mnt/jp4/params \
        || echo "jp5-chroot-prep: WARN bind /params 到 chroot 失败(非致命)" >&2
    return 0
}
params_prep || true

exit 0
