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

# ---- 可选:R32 用户态兼容垫片的数据文件(AI 相机 EGL/argus 前置),失败只告警 ----
# 2026-07-28: R32(JP4) 的 libnvscf 有一套【独立于 libnvrm 的】芯片 ID 读取器,
# 只认这两条路径,没有 /sys/devices/soc0 回落:
#     /sys/module/tegra_fuse/parameters/tegra_chip_id   ← R35 内核没有这个模块
#     /tmp/tegra_chip_id                                ← NVIDIA 官方覆盖钩子
# 读不到就 "Unknown HW element! Using default settings!" → PowerServiceHwIsp
# 报 "Tegra chip ID not supported" → createCameraProvider 失败 → camera_server
# assert 崩溃(abort 循环)。这里按 soc0 的真实值把两条路都铺上。
# 配套的 ioctl 翻译层是 /opt/nvgpu-r32-shim.so(源码 dog-scripts/src/)。
r32_compat_prep() {
    local soc=/sys/devices/soc0 dir=/mnt/jp4/opt/nvgpu-r32-compat
    [ -r "$soc/soc_id" ] || { echo "jp5-chroot-prep: 无 soc0/soc_id,跳过 r32 兼容层" >&2; return 0; }
    mkdir -p "$dir" || return 0
    # chip_id: shim 把 tegra_fuse 路径改道到这里(libnvrm 自己能回落,主要是喂 libnvscf)
    cp -f "$soc/soc_id" "$dir/tegra_chip_id" 2>/dev/null || true
    # platform: R32 这个参数收的是【名字】(silicon/fpga/sim/qt),不是数字 ——
    # 直接把 R35 的 soc0/platform("0") 抄过去会让 libnvrm 打 "Unknown platform '0'"。
    # 只在确认是 silicon(0) 时写名字;其他值宁可不写,让 R32 走它自己的默认
    # (缺这个文件时它本来就默认 silicon,只是会多打一行提示)。
    if [ "$(cat "$soc/platform" 2>/dev/null)" = "0" ]; then
        echo silicon > "$dir/tegra_platform" 2>/dev/null || true
    else
        rm -f "$dir/tegra_platform" 2>/dev/null || true
    fi
    chmod 644 "$dir"/* 2>/dev/null || true
    # libnvscf 的官方后路(双保险;/tmp 可能被开机清理,所以每次都写)
    cp -f "$soc/soc_id" /mnt/jp4/tmp/tegra_chip_id 2>/dev/null || true
    chmod 644 /mnt/jp4/tmp/tegra_chip_id 2>/dev/null || true
    return 0
}
r32_compat_prep || true

# ---- 可选:相机模块 badge/position 覆盖(AI 相机 ISP 配置加载),失败只告警 ----
# 2026-07-28: 我们移植的 DTB 里 tegra-camera-platform 用的是 NVIDIA P2151 参考板
# 的写法(badge="ov13b10_2_P2151X"、position="2"),而 libnvodm_imager 认的位置名是
# 一个【固定集合】: bottom/center/centerleft/centerright/front/rear —— 对不上就
# "Could not map module to ISP config string",三个模块的 .isp 全加载不了
# (磁盘上的出厂配置叫 ov13b10_bottom_RBP194.isp 等,按 badge 命名查找)。
# 出厂 DTB 用的是 badge="ov13b10_bottom_RBP194"、position="bottom"。
# 这里通过 shim 的 DT 覆盖机制补上,实测三个 .isp 全部加载成功。
# ⚠️ DT 属性是 NUL 结尾字符串,必须用 printf 写出结尾的 \0。
# ⚠️ 这是运行时兜底;正解是修 DTB 源码里的 tegra-camera-platform 节点
#    (还应把 module 顺序改回出厂的 module0=ov13b10,因为 camera_server 开的是 id 0)。
r32_camera_dt_prep() {
    local base=/mnt/jp4/opt/nvgpu-r32-compat/dt/tegra-camera-platform/modules
    local m
    # 我们 DTB 的模块序: module0=ov7251_a@61, module1=ov7251_b@62, module2=ov13b10@36
    for m in module0 module1 module2; do
        mkdir -p "$base/$m" 2>/dev/null || return 0
    done
    printf 'ov7251_l_center_RBP194\0' > "$base/module0/badge"    2>/dev/null || true
    printf 'center\0'                > "$base/module0/position" 2>/dev/null || true
    printf 'ov7251_top_RBP194\0'     > "$base/module1/badge"    2>/dev/null || true
    printf 'front\0'                 > "$base/module1/position" 2>/dev/null || true
    printf 'ov13b10_bottom_RBP194\0' > "$base/module2/badge"    2>/dev/null || true
    printf 'bottom\0'                > "$base/module2/position" 2>/dev/null || true
    chmod -R a+rX /mnt/jp4/opt/nvgpu-r32-compat/dt 2>/dev/null || true
    return 0
}
r32_camera_dt_prep || true

exit 0
